import XCTest
@testable import Fantastty

@MainActor
final class RemoteGridSurfaceRendererTests: XCTestCase {
    func testTentativeRowsUseStructuredCellsAndDoNotFallBackToPlainText() {
        let state = makeState(text: "$  ")
        let overlay = RemotePaneOverlay(
            cells: [
                RemotePaneOverlayCell(row: 0, column: 1, cell: .text("a", style: .tentativePrediction))
            ],
            cursor: nil
        )
        guard let display = state.displayCopy(applying: overlay) else {
            return XCTFail("Expected valid display copy")
        }
        let surface = FakeRemoteGridSurface()
        surface.rejectStructuredRows.insert(0)

        let result = RemoteGridSurfaceRenderer().render(display, into: surface)

        XCTAssertEqual(result, .rejectedBySurface(stage: .row(0)))
        XCTAssertEqual(surface.structuredRows, [0])
        XCTAssertTrue(surface.plainTextRows.isEmpty)
    }

    func testAuthoritativeRowsStillUsePlainTextFallback() {
        let state = makeState(text: "$ a")
        let surface = FakeRemoteGridSurface()
        surface.rejectStructuredRows.insert(0)

        let result = RemoteGridSurfaceRenderer().render(state, into: surface)

        XCTAssertEqual(result, .rendered)
        XCTAssertEqual(surface.structuredRows, [0])
        XCTAssertEqual(surface.plainTextRows, [0])
    }

    func testExistingSameSizeGridCanRenderWithoutDestructiveReset() {
        let state = makeState(text: "$ a")
        let surface = FakeRemoteGridSurface()

        let result = RemoteGridSurfaceRenderer().render(state, into: surface, resetGrid: false)

        XCTAssertEqual(result, .rendered)
        XCTAssertEqual(surface.resetCount, 0)
        XCTAssertEqual(surface.structuredRows, [0])
        XCTAssertEqual(surface.cursor, RemoteCursorState(row: 0, column: 2, visible: true, shape: .block))
    }

    func testExistingSameSizeGridCanRenderChangedRowsOnly() {
        let state = makeState(rows: ["one", "two"])
        let surface = FakeRemoteGridSurface()

        let result = RemoteGridSurfaceRenderer().render(
            state,
            into: surface,
            resetGrid: false,
            rowsToRender: [1]
        )

        XCTAssertEqual(result, .rendered)
        XCTAssertEqual(surface.resetCount, 0)
        XCTAssertEqual(surface.structuredRows, [1])
    }

    private func makeState(text: String) -> RemotePaneGridState {
        makeState(rows: [text])
    }

    private func makeState(rows textRows: [String]) -> RemotePaneGridState {
        var state = RemotePaneGridState.empty
        let columns = textRows.map(\.count).max() ?? 1
        let keyframe = RemotePaneKeyframe(
            workspaceID: "workspace-1",
            paneID: 7,
            paneGeneration: 3,
            keyframeID: 11,
            gridSize: RemoteGridSize(columns: columns, rows: textRows.count),
            rows: textRows.enumerated().map { index, text in
                RemoteGridRow(index: index, rowVersion: UInt64(index + 1), cells: paddedCells(text, columns: columns))
            },
            cursor: RemoteCursorState(row: 0, column: min(textRows.first?.count ?? 0, columns - 1), visible: true, shape: .block),
            activeScreen: .primary,
            datagramsEnabledAfterKeyframe: true
        )
        XCTAssertEqual(state.apply(keyframe), .applied)
        return state
    }

    private func paddedCells(_ text: String, columns: Int) -> [RemoteGridCell] {
        var cells = text.map { RemoteGridCell.text(String($0)) }
        while cells.count < columns {
            cells.append(.blank)
        }
        return Array(cells.prefix(columns))
    }
}

@MainActor
private final class FakeRemoteGridSurface: RemoteGridSurface {
    var rejectStructuredRows: Set<Int> = []
    var resetCount = 0
    var structuredRows: [Int] = []
    var plainTextRows: [Int] = []
    var cursor: RemoteCursorState?

    func resetRemoteGrid(columns: Int, rows: Int) -> Bool {
        resetCount += 1
        return true
    }

    func setRemoteGridRow(_ row: Int, text: String) -> Bool {
        plainTextRows.append(row)
        return true
    }

    func setRemoteGridRow(_ row: Int, cells: [RemoteGridCell]) -> Bool {
        structuredRows.append(row)
        return !rejectStructuredRows.contains(row)
    }

    func setRemoteGridCursor(_ cursor: RemoteCursorState) -> Bool {
        self.cursor = cursor
        return true
    }
}
