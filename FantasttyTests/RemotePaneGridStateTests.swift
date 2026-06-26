import XCTest
@testable import Fantastty

final class RemotePaneGridStateTests: XCTestCase {
    func testKeyframeInitializesVisibleGridState() {
        let keyframe = makeKeyframe(
            rows: [
                [.text("h"), .text("i"), .blank],
                [.text("o"), .text("k"), .blank]
            ],
            rowVersions: [5, 6]
        )

        var state = RemotePaneGridState.empty
        let result = state.apply(keyframe)

        XCTAssertEqual(result, .applied)
        XCTAssertEqual(state.workspaceID, "workspace-1")
        XCTAssertEqual(state.paneID, 7)
        XCTAssertEqual(state.paneGeneration, 3)
        XCTAssertEqual(state.keyframeID, 11)
        XCTAssertEqual(state.gridSize, RemoteGridSize(columns: 3, rows: 2))
        XCTAssertEqual(state.rows, keyframe.rows.map(\.cells))
        XCTAssertEqual(state.rowVersions, [5, 6])
        XCTAssertEqual(state.cursor, keyframe.cursor)
    }

    func testNewerKeyframeReplacesCorruptedState() {
        var state = RemotePaneGridState.empty
        XCTAssertEqual(state.apply(makeKeyframe(rows: [
            [.text("b"), .text("a"), .text("d")],
            [.text("c"), .text("d"), .blank]
        ])), .applied)

        let replacement = makeKeyframe(
            keyframeID: 12,
            rows: [
                [.text("o"), .text("n"), .text("e")],
                [.text("t"), .text("w"), .text("o")]
            ],
            rowVersions: [30, 31]
        )
        XCTAssertEqual(state.apply(replacement), .applied)

        XCTAssertEqual(state.keyframeID, 12)
        XCTAssertEqual(state.rows, replacement.rows.map(\.cells))
        XCTAssertEqual(state.rowVersions, [30, 31])
    }

    func testStaleKeyframeDoesNotReplaceCurrentState() {
        var state = RemotePaneGridState.empty
        XCTAssertEqual(state.apply(makeKeyframe(keyframeID: 12)), .applied)

        let stale = makeKeyframe(keyframeID: 11, rows: [
            [.text("o"), .text("l"), .text("d")],
            [.text("r"), .text("o"), .text("w")]
        ])

        XCTAssertEqual(state.apply(stale), .dropped(.staleKeyframe))
        XCTAssertEqual(state.keyframeID, 12)
        XCTAssertEqual(state.rows[0], [.text("a"), .text("b"), .blank])
    }

    func testMalformedKeyframeIsRejected() {
        let malformed = makeKeyframe(rows: [[.text("x")]], rowVersions: [1])
        var state = RemotePaneGridState.empty

        XCTAssertEqual(state.apply(malformed), .needsKeyframe(.malformedKeyframe))
        XCTAssertNil(state.workspaceID)
    }

    func testRejectsNonPositiveGridSize() {
        var state = RemotePaneGridState.empty

        XCTAssertEqual(
            state.apply(makeKeyframe(
                gridSize: RemoteGridSize(columns: 0, rows: 2),
                rows: [[], []]
            )),
            .needsKeyframe(.malformedKeyframe)
        )

        XCTAssertEqual(
            state.apply(makeKeyframe(
                gridSize: RemoteGridSize(columns: 3, rows: 0),
                rows: [],
                rowVersions: []
            )),
            .needsKeyframe(.malformedKeyframe)
        )
    }

    func testRejectsDuplicateRowIndex() {
        let keyframe = makeKeyframe(rowIndices: [0, 0])
        var state = RemotePaneGridState.empty

        XCTAssertEqual(state.apply(keyframe), .needsKeyframe(.malformedKeyframe))
    }

    func testRejectsOutOfRangeRowIndex() {
        let keyframe = makeKeyframe(rowIndices: [0, 2])
        var state = RemotePaneGridState.empty

        XCTAssertEqual(state.apply(keyframe), .needsKeyframe(.malformedKeyframe))
    }

    func testRejectsRowsWithWrongCellCount() {
        let keyframe = makeKeyframe(rows: [
            [.text("a"), .text("b")],
            [.text("c"), .text("d"), .blank]
        ])
        var state = RemotePaneGridState.empty

        XCTAssertEqual(state.apply(keyframe), .needsKeyframe(.malformedKeyframe))
    }

    func testRejectsWideCellWithoutContinuation() {
        let keyframe = makeKeyframe(rows: [
            [.text("w", width: 2), .text("x"), .blank],
            [.text("c"), .text("d"), .blank]
        ])
        var state = RemotePaneGridState.empty

        XCTAssertEqual(state.apply(keyframe), .needsKeyframe(.malformedKeyframe))
    }

    func testRejectsStandaloneContinuationCell() {
        let keyframe = makeKeyframe(rows: [
            [.continuation, .text("a"), .blank],
            [.text("c"), .text("d"), .blank]
        ])
        var state = RemotePaneGridState.empty

        XCTAssertEqual(state.apply(keyframe), .needsKeyframe(.malformedKeyframe))
    }

    func testRejectsNonCanonicalContinuationCell() {
        let keyframe = makeKeyframe(rows: [
            [.text("w", width: 2), RemoteGridCell(text: "x", width: 0, style: .normal), .blank],
            [.text("c"), .text("d"), .blank]
        ])
        var state = RemotePaneGridState.empty

        XCTAssertEqual(state.apply(keyframe), .needsKeyframe(.malformedKeyframe))
    }

    func testAcceptsCanonicalContinuationCell() {
        let keyframe = makeKeyframe(rows: [
            [.text("界", width: 2), .continuation, .blank],
            [.text("c"), .text("d"), .blank]
        ])
        var state = RemotePaneGridState.empty

        XCTAssertEqual(state.apply(keyframe), .applied)
        XCTAssertEqual(state.rows[0], [.text("界", width: 2), .continuation, .blank])
    }

    func testRejectsNarrowTextMarkedAsWideCell() {
        let keyframe = makeKeyframe(rows: [
            [.text("w", width: 2), .continuation, .blank],
            [.text("c"), .text("d"), .blank]
        ])
        var state = RemotePaneGridState.empty

        XCTAssertEqual(state.apply(keyframe), .needsKeyframe(.malformedKeyframe))
    }

    func testRejectsCursorOutsideGridBounds() {
        let keyframe = makeKeyframe(cursor: RemoteCursorState(
            row: 2,
            column: 0,
            visible: true,
            shape: .block
        ))
        var state = RemotePaneGridState.empty

        XCTAssertEqual(state.apply(keyframe), .needsKeyframe(.malformedKeyframe))
    }

    func testWrongWorkspaceDropTakesPrecedenceOverMalformedStructure() {
        var state = RemotePaneGridState.empty
        XCTAssertEqual(state.apply(makeKeyframe()), .applied)

        let wrongWorkspace = makeKeyframe(
            workspaceID: "workspace-2",
            rows: [[.text("x")]],
            rowVersions: [1]
        )

        XCTAssertEqual(state.apply(wrongWorkspace), .dropped(.wrongWorkspace))
        XCTAssertEqual(state.workspaceID, "workspace-1")
    }

    func testStaleKeyframeDropTakesPrecedenceOverMalformedStructure() {
        var state = RemotePaneGridState.empty
        XCTAssertEqual(state.apply(makeKeyframe(keyframeID: 12)), .applied)

        let stale = makeKeyframe(
            keyframeID: 11,
            rows: [[.text("x")]],
            rowVersions: [1]
        )

        XCTAssertEqual(state.apply(stale), .dropped(.staleKeyframe))
        XCTAssertEqual(state.keyframeID, 12)
    }

    func testDeltaAppliesFullRowsAndCursorWhenIdentityMatches() {
        var state = RemotePaneGridState.empty
        XCTAssertEqual(state.apply(makeKeyframe()), .applied)

        let cursor = RemoteCursorState(row: 1, column: 2, visible: true, shape: .bar, cursorVersion: 2)
        let delta = RemotePaneDelta(
            workspaceID: "workspace-1",
            paneID: 7,
            paneGeneration: 3,
            baseKeyframeID: 11,
            deltaSequence: 1,
            rowUpdates: [
                RemoteRowUpdate(rowIndex: 0, rowVersion: 10, update: .fullRow([
                    .text("n"), .text("e"), .text("w")
                ]))
            ],
            cursor: cursor
        )

        XCTAssertEqual(state.apply(delta), .applied)
        XCTAssertEqual(state.rows[0], [.text("n"), .text("e"), .text("w")])
        XCTAssertEqual(state.rowVersions[0], 10)
        XCTAssertEqual(state.cursor, cursor)
        XCTAssertEqual(state.lastDeltaSequence, 1)
    }

    func testDeltaSkipsStaleCursorInsideOtherwiseValidDelta() {
        let initialCursor = RemoteCursorState(
            row: 0,
            column: 0,
            visible: true,
            shape: .block,
            cursorVersion: 5
        )
        var state = RemotePaneGridState.empty
        XCTAssertEqual(state.apply(makeKeyframe(cursor: initialCursor)), .applied)

        let staleCursor = RemoteCursorState(
            row: 1,
            column: 2,
            visible: true,
            shape: .bar,
            cursorVersion: 5
        )
        let delta = RemotePaneDelta(
            workspaceID: "workspace-1",
            paneID: 7,
            paneGeneration: 3,
            baseKeyframeID: 11,
            deltaSequence: 1,
            rowUpdates: [
                RemoteRowUpdate(rowIndex: 0, rowVersion: 10, update: .fullRow([
                    .text("n"), .text("e"), .text("w")
                ]))
            ],
            cursor: staleCursor
        )

        XCTAssertEqual(state.apply(delta), .applied)
        XCTAssertEqual(state.rows[0], [.text("n"), .text("e"), .text("w")])
        XCTAssertEqual(state.cursor, initialCursor)
    }

    func testOlderUsefulRowDeltaAppliesAfterNewerCursorOnlyDelta() {
        var state = RemotePaneGridState.empty
        XCTAssertEqual(state.apply(makeKeyframe()), .applied)

        let cursorOnlyDelta = RemotePaneDelta(
            workspaceID: "workspace-1",
            paneID: 7,
            paneGeneration: 3,
            baseKeyframeID: 11,
            deltaSequence: 2,
            rowUpdates: [],
            cursor: RemoteCursorState(row: 1, column: 2, visible: true, shape: .bar, cursorVersion: 2)
        )
        let olderRowDelta = RemotePaneDelta(
            workspaceID: "workspace-1",
            paneID: 7,
            paneGeneration: 3,
            baseKeyframeID: 11,
            deltaSequence: 1,
            rowUpdates: [
                RemoteRowUpdate(rowIndex: 0, rowVersion: 10, update: .fullRow([
                    .text("n"), .text("e"), .text("w")
                ]))
            ],
            cursor: nil
        )

        XCTAssertEqual(state.apply(cursorOnlyDelta), .applied)
        XCTAssertEqual(state.apply(olderRowDelta), .applied)
        XCTAssertEqual(state.rows[0], [.text("n"), .text("e"), .text("w")])
        XCTAssertEqual(state.rowVersions[0], 10)
        XCTAssertEqual(state.cursor, cursorOnlyDelta.cursor)
        XCTAssertEqual(state.lastDeltaSequence, 2)
    }

    func testDeltaAppliesSpanAndClearsStaleTail() {
        var state = RemotePaneGridState.empty
        XCTAssertEqual(state.apply(makeKeyframe(rows: [
            [.text("a"), .text("b"), .text("c")],
            [.text("d"), .text("e"), .text("f")]
        ])), .applied)

        let delta = RemotePaneDelta(
            workspaceID: "workspace-1",
            paneID: 7,
            paneGeneration: 3,
            baseKeyframeID: 11,
            deltaSequence: 1,
            rowUpdates: [
                RemoteRowUpdate(
                    rowIndex: 0,
                    rowVersion: 10,
                    update: .span(baseRowVersion: 1, startColumn: 1, cells: [.text("x")], clearToColumn: 3)
                )
            ],
            cursor: nil
        )

        XCTAssertEqual(state.apply(delta), .applied)
        XCTAssertEqual(state.rows[0], [.text("a"), .text("x"), .blank])
        XCTAssertEqual(state.rowVersions[0], 10)
    }

    func testDeltaAppliesSpanWhenBaseRowVersionMatchesCurrentRowVersion() {
        var state = RemotePaneGridState.empty
        XCTAssertEqual(state.apply(makeKeyframe(rows: [
            [.text("a"), .text("b"), .text("c")],
            [.text("d"), .text("e"), .text("f")]
        ], rowVersions: [5, 6])), .applied)

        let delta = RemotePaneDelta(
            workspaceID: "workspace-1",
            paneID: 7,
            paneGeneration: 3,
            baseKeyframeID: 11,
            deltaSequence: 1,
            rowUpdates: [
                RemoteRowUpdate(
                    rowIndex: 0,
                    rowVersion: 10,
                    update: .span(baseRowVersion: 5, startColumn: 1, cells: [.text("x")], clearToColumn: 3)
                )
            ],
            cursor: nil
        )

        XCTAssertEqual(state.apply(delta), .applied)
        XCTAssertEqual(state.rows[0], [.text("a"), .text("x"), .blank])
        XCTAssertEqual(state.rowVersions[0], 10)
    }

    func testDeltaRequestsKeyframeForSpanWhenBaseRowVersionIsNewerThanCurrentRowVersion() {
        var state = RemotePaneGridState.empty
        XCTAssertEqual(state.apply(makeKeyframe(rows: [
            [.text("a"), .text("b"), .text("c")],
            [.text("d"), .text("e"), .text("f")]
        ], rowVersions: [5, 6])), .applied)
        let originalState = state

        let delta = RemotePaneDelta(
            workspaceID: "workspace-1",
            paneID: 7,
            paneGeneration: 3,
            baseKeyframeID: 11,
            deltaSequence: 1,
            rowUpdates: [
                RemoteRowUpdate(
                    rowIndex: 0,
                    rowVersion: 10,
                    update: .span(baseRowVersion: 6, startColumn: 1, cells: [.text("x")], clearToColumn: 3)
                )
            ],
            cursor: nil
        )

        XCTAssertEqual(state.apply(delta), .needsKeyframe(.rowVersionMismatch))
        XCTAssertEqual(state, originalState)
    }

    func testFullRowLatestDeltaConvergesAfterReorderingOrLoss() {
        var orderedState = RemotePaneGridState.empty
        var reorderedState = RemotePaneGridState.empty
        XCTAssertEqual(orderedState.apply(makeKeyframe(rowVersions: [1, 2])), .applied)
        XCTAssertEqual(reorderedState.apply(makeKeyframe(rowVersions: [1, 2])), .applied)

        let olderDelta = RemotePaneDelta(
            workspaceID: "workspace-1",
            paneID: 7,
            paneGeneration: 3,
            baseKeyframeID: 11,
            deltaSequence: 1,
            rowUpdates: [
                RemoteRowUpdate(rowIndex: 0, rowVersion: 3, update: .fullRow([
                    .text("o"), .text("l"), .text("d")
                ]))
            ],
            cursor: RemoteCursorState(row: 0, column: 1, visible: true, shape: .bar)
        )
        let latestDelta = RemotePaneDelta(
            workspaceID: "workspace-1",
            paneID: 7,
            paneGeneration: 3,
            baseKeyframeID: 11,
            deltaSequence: 2,
            rowUpdates: [
                RemoteRowUpdate(rowIndex: 0, rowVersion: 4, update: .fullRow([
                    .text("n"), .text("e"), .text("w")
                ]))
            ],
            cursor: RemoteCursorState(row: 1, column: 2, visible: true, shape: .underline)
        )

        XCTAssertEqual(orderedState.apply(olderDelta), .applied)
        XCTAssertEqual(orderedState.apply(latestDelta), .applied)
        XCTAssertEqual(reorderedState.apply(latestDelta), .applied)
        XCTAssertEqual(reorderedState.apply(olderDelta), .dropped(.staleDelta))

        XCTAssertEqual(reorderedState.rows, orderedState.rows)
        XCTAssertEqual(reorderedState.rowVersions, orderedState.rowVersions)
        XCTAssertEqual(reorderedState.cursor, orderedState.cursor)
        XCTAssertEqual(reorderedState.lastDeltaSequence, orderedState.lastDeltaSequence)
    }

    func testDeterministicLossyHarnessConvergesOnlyFromValidKeyframeBase() {
        let script = makeDeterministicLossyHarnessScript()
        let oracle = makeStructuredStateOracle(for: script)
        let schedules = makeDeterministicLossySchedules()

        for schedule in schedules {
            assertLossySchedule(
                schedule,
                for: script,
                convergesFromValidBaseTo: oracle
            )

            assertLossyScheduleDoesNotConvergeWithoutValidBase(
                schedule,
                for: script,
                oracle: oracle
            )
        }
    }

    func testDeltaDropsWrongWorkspaceWithoutChangingState() {
        var state = RemotePaneGridState.empty
        XCTAssertEqual(state.apply(makeKeyframe()), .applied)

        let delta = makeDelta(workspaceID: "other-workspace", deltaSequence: 1)

        XCTAssertEqual(state.apply(delta), .dropped(.wrongWorkspace))
        XCTAssertEqual(state.rows[0], [.text("a"), .text("b"), .blank])
        XCTAssertEqual(state.lastDeltaSequence, 0)
    }

    func testDeltaRequestsKeyframeForBaseKeyframeMismatch() {
        var state = RemotePaneGridState.empty
        XCTAssertEqual(state.apply(makeKeyframe()), .applied)

        let delta = makeDelta(baseKeyframeID: 10, deltaSequence: 1)

        XCTAssertEqual(state.apply(delta), .needsKeyframe(.baseKeyframeMismatch))
        XCTAssertEqual(state.rows[0], [.text("a"), .text("b"), .blank])
    }

    func testDeltaDropsStaleRowsInsideOtherwiseNewDelta() {
        var state = RemotePaneGridState.empty
        XCTAssertEqual(state.apply(makeKeyframe(rowVersions: [5, 6])), .applied)

        let delta = RemotePaneDelta(
            workspaceID: "workspace-1",
            paneID: 7,
            paneGeneration: 3,
            baseKeyframeID: 11,
            deltaSequence: 1,
            rowUpdates: [
                RemoteRowUpdate(rowIndex: 0, rowVersion: 4, update: .fullRow([
                    .text("o"), .text("l"), .text("d")
                ])),
                RemoteRowUpdate(rowIndex: 1, rowVersion: 7, update: .fullRow([
                    .text("n"), .text("e"), .text("w")
                ]))
            ],
            cursor: nil
        )

        XCTAssertEqual(state.apply(delta), .applied)
        XCTAssertEqual(state.rows[0], [.text("a"), .text("b"), .blank])
        XCTAssertEqual(state.rows[1], [.text("n"), .text("e"), .text("w")])
        XCTAssertEqual(state.rowVersions, [5, 7])
    }

    func testMalformedSpanRequestsKeyframe() {
        var state = RemotePaneGridState.empty
        XCTAssertEqual(state.apply(makeKeyframe()), .applied)

        let delta = RemotePaneDelta(
            workspaceID: "workspace-1",
            paneID: 7,
            paneGeneration: 3,
            baseKeyframeID: 11,
            deltaSequence: 1,
            rowUpdates: [
                RemoteRowUpdate(
                    rowIndex: 0,
                    rowVersion: 10,
                    update: .span(baseRowVersion: 1, startColumn: 2, cells: [.text("x"), .text("y")], clearToColumn: nil)
                )
            ],
            cursor: nil
        )

        XCTAssertEqual(state.apply(delta), .needsKeyframe(.malformedDelta))
        XCTAssertEqual(state.rows[0], [.text("a"), .text("b"), .blank])
    }

    func testDeltaRejectsSpanStartingInsideWideCellWithoutChangingState() {
        var state = RemotePaneGridState.empty
        XCTAssertEqual(state.apply(makeKeyframe(rows: [
            [.text("界", width: 2), .continuation, .text("z")],
            [.text("c"), .text("d"), .blank]
        ])), .applied)
        let originalState = state

        let delta = RemotePaneDelta(
            workspaceID: "workspace-1",
            paneID: 7,
            paneGeneration: 3,
            baseKeyframeID: 11,
            deltaSequence: 1,
            rowUpdates: [
                RemoteRowUpdate(
                    rowIndex: 0,
                    rowVersion: 10,
                    update: .span(baseRowVersion: 1, startColumn: 1, cells: [.text("x")], clearToColumn: nil)
                )
            ],
            cursor: nil
        )

        XCTAssertEqual(state.apply(delta), .needsKeyframe(.malformedDelta))
        XCTAssertEqual(state, originalState)
    }

    func testDeltaRejectsSpanReplacingOnlyFirstHalfOfWideCellWithoutChangingState() {
        var state = RemotePaneGridState.empty
        XCTAssertEqual(state.apply(makeKeyframe(rows: [
            [.text("界", width: 2), .continuation, .text("z")],
            [.text("c"), .text("d"), .blank]
        ])), .applied)
        let originalState = state

        let delta = RemotePaneDelta(
            workspaceID: "workspace-1",
            paneID: 7,
            paneGeneration: 3,
            baseKeyframeID: 11,
            deltaSequence: 1,
            rowUpdates: [
                RemoteRowUpdate(
                    rowIndex: 0,
                    rowVersion: 10,
                    update: .span(baseRowVersion: 1, startColumn: 0, cells: [.text("x")], clearToColumn: nil)
                )
            ],
            cursor: nil
        )

        XCTAssertEqual(state.apply(delta), .needsKeyframe(.malformedDelta))
        XCTAssertEqual(state, originalState)
    }

    func testDeltaRejectsSpanTailClearingThatLeavesOrphanContinuationWithoutChangingState() {
        var state = RemotePaneGridState.empty
        XCTAssertEqual(state.apply(makeKeyframe(rows: [
            [.text("a"), .text("界", width: 2), .continuation],
            [.text("c"), .text("d"), .blank]
        ])), .applied)
        let originalState = state

        let delta = RemotePaneDelta(
            workspaceID: "workspace-1",
            paneID: 7,
            paneGeneration: 3,
            baseKeyframeID: 11,
            deltaSequence: 1,
            rowUpdates: [
                RemoteRowUpdate(
                    rowIndex: 0,
                    rowVersion: 10,
                    update: .span(baseRowVersion: 1, startColumn: 1, cells: [.text("x")], clearToColumn: 2)
                )
            ],
            cursor: nil
        )

        XCTAssertEqual(state.apply(delta), .needsKeyframe(.malformedDelta))
        XCTAssertEqual(state, originalState)
    }

    func testDisplayCopyAppliesTentativeCellsAndCursorWithoutMutatingAuthoritativeState() {
        var state = RemotePaneGridState.empty
        XCTAssertEqual(state.apply(makeKeyframe(
            gridSize: RemoteGridSize(columns: 3, rows: 1),
            rows: [[.text("$"), .blank, .blank]],
            rowVersions: [1],
            cursor: RemoteCursorState(row: 0, column: 1, visible: true, shape: .block)
        )), .applied)

        let overlay = RemotePaneOverlay(
            cells: [
                RemotePaneOverlayCell(row: 0, column: 1, cell: .text("a", style: .tentativePrediction))
            ],
            cursor: RemoteCursorState(row: 0, column: 2, visible: true, shape: .block)
        )

        let display = state.displayCopy(applying: overlay)

        XCTAssertEqual(display?.rows[0][1].text, "a")
        XCTAssertEqual(display?.tentativeRows, [0])
        XCTAssertEqual(display?.cursor?.column, 2)
        XCTAssertEqual(state.rows[0][1], .blank)
        XCTAssertEqual(state.tentativeRows, [])
        XCTAssertEqual(state.cursor?.column, 1)
    }

    func testDisplayCopyRejectsOutOfBoundsTentativeCells() {
        var state = RemotePaneGridState.empty
        XCTAssertEqual(state.apply(makeKeyframe(
            gridSize: RemoteGridSize(columns: 3, rows: 1),
            rows: [[.text("$"), .blank, .blank]],
            rowVersions: [1]
        )), .applied)

        let overlay = RemotePaneOverlay(
            cells: [
                RemotePaneOverlayCell(row: 0, column: 3, cell: .text("x", style: .tentativePrediction))
            ],
            cursor: nil
        )

        XCTAssertNil(state.displayCopy(applying: overlay))
        XCTAssertEqual(state.rows[0], [.text("$"), .blank, .blank])
    }

    func testDisplayCopyRejectsMalformedWideCellOverlay() {
        var state = RemotePaneGridState.empty
        XCTAssertEqual(state.apply(makeKeyframe(
            gridSize: RemoteGridSize(columns: 3, rows: 1),
            rows: [[.text("$"), .blank, .blank]],
            rowVersions: [1]
        )), .applied)

        let overlay = RemotePaneOverlay(
            cells: [
                RemotePaneOverlayCell(row: 0, column: 2, cell: .text("界", width: 2, style: .tentativePrediction))
            ],
            cursor: nil
        )

        XCTAssertNil(state.displayCopy(applying: overlay))
    }

    func testDeltaWrongWorkspaceDropTakesPrecedenceOverMalformedStructure() {
        var state = RemotePaneGridState.empty
        XCTAssertEqual(state.apply(makeKeyframe()), .applied)
        let originalState = state

        let delta = RemotePaneDelta(
            workspaceID: "other-workspace",
            paneID: 7,
            paneGeneration: 3,
            baseKeyframeID: 11,
            deltaSequence: 1,
            rowUpdates: [
                RemoteRowUpdate(
                    rowIndex: 9,
                    rowVersion: 10,
                    update: .span(baseRowVersion: 1, startColumn: 3, cells: [], clearToColumn: nil)
                )
            ],
            cursor: RemoteCursorState(row: 9, column: 9, visible: true, shape: .bar)
        )

        XCTAssertEqual(state.apply(delta), .dropped(.wrongWorkspace))
        XCTAssertEqual(state, originalState)
    }

    func testDeltaWithoutKeyframeRequestsKeyframe() {
        var state = RemotePaneGridState.empty

        XCTAssertEqual(state.apply(makeDelta()), .needsKeyframe(.noKeyframe))
    }

    func testDeltaAfterKeyframeWithDatagramsDisabledRequestsKeyframe() {
        var state = RemotePaneGridState.empty
        XCTAssertEqual(state.apply(makeKeyframe(datagramsEnabledAfterKeyframe: false)), .applied)
        let originalState = state

        XCTAssertEqual(state.apply(makeDelta()), .needsKeyframe(.datagramsDisabled))
        XCTAssertEqual(state, originalState)
    }

    func testDeltaDropsWrongPane() {
        var state = RemotePaneGridState.empty
        XCTAssertEqual(state.apply(makeKeyframe()), .applied)
        let originalState = state

        XCTAssertEqual(state.apply(makeDelta(paneID: 9)), .dropped(.wrongPane))
        XCTAssertEqual(state, originalState)
    }

    func testDeltaDropsOlderGeneration() {
        var state = RemotePaneGridState.empty
        XCTAssertEqual(state.apply(makeKeyframe()), .applied)
        let originalState = state

        XCTAssertEqual(state.apply(makeDelta(paneGeneration: 2)), .dropped(.staleGeneration))
        XCTAssertEqual(state, originalState)
    }

    func testDeltaRequestsKeyframeForNewerGeneration() {
        var state = RemotePaneGridState.empty
        XCTAssertEqual(state.apply(makeKeyframe()), .applied)
        let originalState = state

        XCTAssertEqual(state.apply(makeDelta(paneGeneration: 4)), .needsKeyframe(.generationMismatch))
        XCTAssertEqual(state, originalState)
    }

    func testStaleKeyframeGenerationDoesNotReplaceCurrentState() {
        var state = RemotePaneGridState.empty
        XCTAssertEqual(state.apply(makeKeyframe(paneGeneration: 4, keyframeID: 12)), .applied)
        let originalState = state

        let stale = makeKeyframe(
            paneGeneration: 3,
            keyframeID: 99,
            rows: [
                [.text("o"), .text("l"), .text("d")],
                [.text("r"), .text("o"), .text("w")]
            ],
            rowVersions: [90, 91]
        )

        XCTAssertEqual(state.apply(stale), .dropped(.staleGeneration))
        XCTAssertEqual(state, originalState)
    }

    func testNewerGenerationKeyframeReplacesDeltaStateAndAcceptsFirstDelta() {
        var state = RemotePaneGridState.empty
        XCTAssertEqual(state.apply(makeKeyframe()), .applied)
        XCTAssertEqual(state.apply(makeDelta(deltaSequence: 1)), .applied)
        XCTAssertEqual(state.lastDeltaSequence, 1)

        let newerKeyframe = makeKeyframe(
            paneGeneration: 4,
            keyframeID: 21,
            rows: [
                [.text("x"), .text("y"), .blank],
                [.text("z"), .blank, .blank]
            ],
            rowVersions: [20, 21],
            cursor: RemoteCursorState(row: 1, column: 0, visible: true, shape: .underline)
        )

        XCTAssertEqual(state.apply(newerKeyframe), .applied)
        XCTAssertEqual(state.paneGeneration, 4)
        XCTAssertEqual(state.keyframeID, 21)
        XCTAssertEqual(state.rows, newerKeyframe.rows.map(\.cells))
        XCTAssertEqual(state.rowVersions, [20, 21])
        XCTAssertEqual(state.lastDeltaSequence, 0)

        let firstDeltaForGeneration = RemotePaneDelta(
            workspaceID: "workspace-1",
            paneID: 7,
            paneGeneration: 4,
            baseKeyframeID: 21,
            deltaSequence: 1,
            rowUpdates: [
                RemoteRowUpdate(rowIndex: 1, rowVersion: 22, update: .fullRow([
                    .text("n"), .text("e"), .text("w")
                ]))
            ],
            cursor: RemoteCursorState(row: 0, column: 2, visible: true, shape: .bar, cursorVersion: 2)
        )

        XCTAssertEqual(state.apply(firstDeltaForGeneration), .applied)
        XCTAssertEqual(state.rows[1], [.text("n"), .text("e"), .text("w")])
        XCTAssertEqual(state.rowVersions, [20, 22])
        XCTAssertEqual(state.lastDeltaSequence, 1)
        XCTAssertEqual(state.cursor, firstDeltaForGeneration.cursor)
    }

    func testDeltaDropsStaleSequence() {
        var state = RemotePaneGridState.empty
        XCTAssertEqual(state.apply(makeKeyframe()), .applied)
        XCTAssertEqual(state.apply(makeDelta(deltaSequence: 2)), .applied)
        let originalState = state

        let staleDelta = RemotePaneDelta(
            workspaceID: "workspace-1",
            paneID: 7,
            paneGeneration: 3,
            baseKeyframeID: 11,
            deltaSequence: 1,
            rowUpdates: [
                RemoteRowUpdate(rowIndex: 0, rowVersion: 9, update: .fullRow([
                    .text("b"), .text("a"), .text("d")
                ]))
            ],
            cursor: RemoteCursorState(row: 1, column: 2, visible: true, shape: .bar)
        )

        XCTAssertEqual(state.apply(staleDelta), .dropped(.staleDelta))
        XCTAssertEqual(state, originalState)
    }

    func testDeltaRejectsOutOfBoundsCursorWithoutChangingState() {
        var state = RemotePaneGridState.empty
        XCTAssertEqual(state.apply(makeKeyframe()), .applied)
        let originalState = state

        let delta = RemotePaneDelta(
            workspaceID: "workspace-1",
            paneID: 7,
            paneGeneration: 3,
            baseKeyframeID: 11,
            deltaSequence: 1,
            rowUpdates: [],
            cursor: RemoteCursorState(row: 2, column: 0, visible: true, shape: .bar)
        )

        XCTAssertEqual(state.apply(delta), .needsKeyframe(.malformedDelta))
        XCTAssertEqual(state, originalState)
    }
}

private extension RemotePaneGridStateTests {
    struct DeterministicLossyHarnessScript {
        let keyframe: RemotePaneKeyframe
        let deltas: [RemotePaneDelta]
    }

    struct DeterministicLossySchedule {
        let name: String
        let deliveredDeltaIndices: [Int]
    }

    func makeDeterministicLossyHarnessScript() -> DeterministicLossyHarnessScript {
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
        let keyframe = makeKeyframe(
            rowVersions: [1, 1],
            cursor: RemoteCursorState(row: 0, column: 0, visible: true, shape: .block, cursorVersion: 1),
            activeScreen: .alternate
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

        return DeterministicLossyHarnessScript(keyframe: keyframe, deltas: deltas)
    }

    func makeDeterministicLossySchedules() -> [DeterministicLossySchedule] {
        [
            DeterministicLossySchedule(name: "drop superseded row delta", deliveredDeltaIndices: [1, 2, 3]),
            DeterministicLossySchedule(name: "duplicate latest cursor delta", deliveredDeltaIndices: [0, 1, 2, 3, 3]),
            DeterministicLossySchedule(name: "reorder independent row deltas", deliveredDeltaIndices: [1, 0, 2, 3]),
            DeterministicLossySchedule(name: "delay useful older row delta", deliveredDeltaIndices: [0, 2, 3, 1])
        ]
    }

    func makeStructuredStateOracle(for script: DeterministicLossyHarnessScript) -> RemotePaneGridState {
        var state = RemotePaneGridState.empty
        XCTAssertEqual(state.apply(script.keyframe), .applied)
        for delta in script.deltas {
            XCTAssertEqual(state.apply(delta), .applied)
        }
        return state
    }

    func assertLossySchedule(
        _ schedule: DeterministicLossySchedule,
        for script: DeterministicLossyHarnessScript,
        convergesFromValidBaseTo oracle: RemotePaneGridState,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var state = RemotePaneGridState.empty
        XCTAssertEqual(state.apply(script.keyframe), .applied, schedule.name, file: file, line: line)

        for index in schedule.deliveredDeltaIndices {
            let result = state.apply(script.deltas[index])
            if case .needsKeyframe = result {
                XCTFail("\(schedule.name) requested a keyframe from a valid base: \(result)", file: file, line: line)
            }
        }

        assertStructuredState(state, equals: oracle, scheduleName: schedule.name, file: file, line: line)
    }

    func assertLossyScheduleDoesNotConvergeWithoutValidBase(
        _ schedule: DeterministicLossySchedule,
        for script: DeterministicLossyHarnessScript,
        oracle: RemotePaneGridState,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var state = RemotePaneGridState.empty
        for index in schedule.deliveredDeltaIndices {
            XCTAssertEqual(state.apply(script.deltas[index]), .needsKeyframe(.noKeyframe), schedule.name, file: file, line: line)
        }

        XCTAssertNotEqual(state, oracle, schedule.name, file: file, line: line)
        XCTAssertNil(state.keyframeID, schedule.name, file: file, line: line)
        XCTAssertTrue(state.rows.isEmpty, schedule.name, file: file, line: line)
        XCTAssertEqual(state.lastDeltaSequence, 0, schedule.name, file: file, line: line)
    }

    func assertStructuredState(
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

    func makeKeyframe(
        workspaceID: String = "workspace-1",
        paneID: Int = 7,
        paneGeneration: UInt64 = 3,
        keyframeID: UInt64 = 11,
        gridSize: RemoteGridSize = RemoteGridSize(columns: 3, rows: 2),
        rows: [[RemoteGridCell]] = [
            [.text("a"), .text("b"), .blank],
            [.text("c"), .text("d"), .blank]
        ],
        rowVersions: [UInt64] = [1, 2],
        rowIndices: [Int]? = nil,
        cursor: RemoteCursorState = RemoteCursorState(row: 0, column: 0, visible: true, shape: .block),
        activeScreen: RemoteActiveScreen = .primary,
        datagramsEnabledAfterKeyframe: Bool = true
    ) -> RemotePaneKeyframe {
        RemotePaneKeyframe(
            workspaceID: workspaceID,
            paneID: paneID,
            paneGeneration: paneGeneration,
            keyframeID: keyframeID,
            gridSize: gridSize,
            rows: rows.enumerated().map { index, cells in
                RemoteGridRow(
                    index: rowIndices?[index] ?? index,
                    rowVersion: rowVersions[index],
                    cells: cells
                )
            },
            cursor: cursor,
            activeScreen: activeScreen,
            datagramsEnabledAfterKeyframe: datagramsEnabledAfterKeyframe
        )
    }

    func makeDelta(
        workspaceID: String = "workspace-1",
        paneID: Int = 7,
        paneGeneration: UInt64 = 3,
        baseKeyframeID: UInt64 = 11,
        deltaSequence: UInt64 = 1
    ) -> RemotePaneDelta {
        RemotePaneDelta(
            workspaceID: workspaceID,
            paneID: paneID,
            paneGeneration: paneGeneration,
            baseKeyframeID: baseKeyframeID,
            deltaSequence: deltaSequence,
            rowUpdates: [
                RemoteRowUpdate(rowIndex: 0, rowVersion: 10, update: .fullRow([
                    .text("n"), .text("e"), .text("w")
                ]))
            ],
            cursor: nil
        )
    }
}
