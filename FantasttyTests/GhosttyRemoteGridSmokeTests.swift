import Foundation
import XCTest
@testable import Fantastty
import GhosttyKit

@MainActor
final class GhosttyRemoteGridSmokeTests: XCTestCase {
    func testRemoteGridWritesVisibleTerminalState() async throws {
        let fixture = try await makeSurface()
        defer { fixture.cleanUp() }

        let surface = fixture.surface
        XCTAssertNotNil(surface.surface)

        guard let surfaceModel = surface.surfaceModel else {
            XCTFail("Ghostty surface model failed to initialize")
            return
        }

        let marker = "FTRG"
        let gridSize = remoteGridSize(for: surface, minimumColumns: marker.count + 1, minimumRows: 1)
        XCTAssertTrue(surfaceModel.resetRemoteGrid(columns: gridSize.columns, rows: gridSize.rows))
        XCTAssertTrue(surfaceModel.setRemoteGridRow(0, text: marker))
        XCTAssertTrue(surfaceModel.setRemoteGridCursor(row: 0, column: marker.count, visible: true))

        try await waitForVisibleText(containing: marker, from: surface)
    }

    func testRemoteWorkspaceBridgeRendersRemoteGridWithDefaultAppConfig() async throws {
        let app = Fantastty.Ghostty.App()
        guard app.app != nil else {
            throw SurfaceFixtureError.ghosttyAppInitializationFailed
        }
        let marker = "FTRG-DEFAULT-APP"
        let bridge = RemoteWorkspaceBridge()
        bridge.ghosttyApp = app
        var diagnostics: [RemoteWorkspaceRenderDiagnostic] = []
        bridge.renderDiagnosticHandler = { diagnostic in
            diagnostics.append(diagnostic)
        }
        let session = Session(title: "Remote", type: .local, workspaceID: "workspace-1")
        bridge.registerRemoteWorkspaceSession(session)

        let gridSize = RemoteGridSize(columns: marker.count + 1, rows: 1)
        bridge.handle(.workspaceSnapshot(RemoteWorkspaceSnapshot(
            workspaceID: "workspace-1",
            layoutGeneration: 1,
            windows: [
                RemoteWorkspaceWindow(windowID: 1, title: "main", index: 0, isActive: true)
            ],
            panes: [
                RemoteWorkspacePane(
                    paneID: 7,
                    windowID: 1,
                    isActive: true,
                    frame: RemotePaneFrame(x: 0, y: 0, columns: gridSize.columns, rows: gridSize.rows)
                )
            ]
        )))
        bridge.handle(.paneKeyframe(RemotePaneKeyframe(
            workspaceID: "workspace-1",
            paneID: 7,
            paneGeneration: 3,
            keyframeID: 11,
            gridSize: gridSize,
            rows: remoteGridRows([marker], gridSize: gridSize, firstRowVersion: 10),
            cursor: RemoteCursorState(row: 0, column: marker.count, visible: true, shape: .block),
            activeScreen: .primary,
            datagramsEnabledAfterKeyframe: true
        )))

        guard let surface = session.tabs.first?.surfaceTree?.root?.leaves().first else {
            XCTFail("Expected remote pane surface")
            return
        }
        try await waitForGhosttySurfaceStartup()
        bridge.handle(.paneKeyframe(RemotePaneKeyframe(
            workspaceID: "workspace-1",
            paneID: 7,
            paneGeneration: 3,
            keyframeID: 12,
            gridSize: gridSize,
            rows: remoteGridRows([marker], gridSize: gridSize, firstRowVersion: 20),
            cursor: RemoteCursorState(row: 0, column: marker.count, visible: true, shape: .block),
            activeScreen: .primary,
            datagramsEnabledAfterKeyframe: true
        )))
        XCTAssertEqual(
            diagnostics.last?.result,
            .rendered,
            diagnostics.map(\.description).joined(separator: " | ")
        )

        try await waitForVisibleText(containing: marker, from: surface)
    }

    func testRemoteWorkspaceBridgeReassertsNativeGridSizeBeforeRender() async throws {
        let app = Fantastty.Ghostty.App()
        guard app.app != nil else {
            throw SurfaceFixtureError.ghosttyAppInitializationFailed
        }
        let marker = "FTRG-RESIZE-DRIFT"
        let bridge = RemoteWorkspaceBridge()
        bridge.ghosttyApp = app
        var diagnostics: [RemoteWorkspaceRenderDiagnostic] = []
        bridge.renderDiagnosticHandler = { diagnostic in
            diagnostics.append(diagnostic)
        }
        let session = Session(title: "Remote", type: .local, workspaceID: "workspace-1")
        bridge.registerRemoteWorkspaceSession(session)

        let gridSize = RemoteGridSize(columns: marker.count + 1, rows: 2)
        bridge.handle(.workspaceSnapshot(RemoteWorkspaceSnapshot(
            workspaceID: "workspace-1",
            layoutGeneration: 1,
            windows: [
                RemoteWorkspaceWindow(windowID: 1, title: "main", index: 0, isActive: true)
            ],
            panes: [
                RemoteWorkspacePane(
                    paneID: 7,
                    windowID: 1,
                    isActive: true,
                    frame: RemotePaneFrame(x: 0, y: 0, columns: gridSize.columns, rows: gridSize.rows)
                )
            ]
        )))

        guard let surface = session.tabs.first?.surfaceTree?.root?.leaves().first else {
            XCTFail("Expected remote pane surface")
            return
        }
        XCTAssertTrue(surface.resizeRemoteGrid(columns: 12, rows: 1))
        surface.surfaceSize = ghostty_surface_size_s(
            columns: UInt16(gridSize.columns),
            rows: UInt16(gridSize.rows),
            width_px: 0,
            height_px: 0,
            cell_width_px: 0,
            cell_height_px: 0
        )

        bridge.handle(.paneKeyframe(RemotePaneKeyframe(
            workspaceID: "workspace-1",
            paneID: 7,
            paneGeneration: 3,
            keyframeID: 11,
            gridSize: gridSize,
            rows: remoteGridRows([marker], gridSize: gridSize, firstRowVersion: 10),
            cursor: RemoteCursorState(row: 0, column: marker.count, visible: true, shape: .block),
            activeScreen: .primary,
            datagramsEnabledAfterKeyframe: true
        )))

        let deadline = Date().addingTimeInterval(3.0)
        while Date() < deadline && diagnostics.last?.result != .rendered {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertEqual(diagnostics.last?.result, .rendered, diagnostics.map(\.description).joined(separator: " | "))
        try await waitForVisibleText(containing: marker, from: surface)
    }

    func testRemoteGridRendererAppliesPaneStateToVisibleTerminalState() async throws {
        let fixture = try await makeSurface()
        defer { fixture.cleanUp() }

        let surface = fixture.surface
        guard let surfaceModel = surface.surfaceModel else {
            XCTFail("Ghostty surface model failed to initialize")
            return
        }

        let marker = "FTRG-STATE"
        let surfaceGridSize = remoteGridSize(for: surface, minimumColumns: marker.count + 1, minimumRows: 2)
        let gridSize = RemoteGridSize(columns: surfaceGridSize.columns, rows: surfaceGridSize.rows)
        let keyframe = RemotePaneKeyframe(
            workspaceID: "workspace-1",
            paneID: 7,
            paneGeneration: 3,
            keyframeID: 11,
            gridSize: gridSize,
            rows: remoteGridRows(
                [
                    marker,
                    "READY"
                ],
                gridSize: gridSize,
                firstRowVersion: 10
            ),
            cursor: RemoteCursorState(row: 0, column: marker.count, visible: true, shape: .block),
            activeScreen: .primary,
            datagramsEnabledAfterKeyframe: true
        )
        var state = RemotePaneGridState.empty
        XCTAssertEqual(state.apply(keyframe), .applied)

        let renderer = RemoteGridSurfaceRenderer()
        XCTAssertEqual(renderer.render(state, into: surfaceModel), .rendered)

        try await waitForVisibleText(containing: marker, from: surface)
    }

    func testRemoteGridRendererAppliesDeltaStateToVisibleTerminalState() async throws {
        let fixture = try await makeSurface()
        defer { fixture.cleanUp() }

        let surface = fixture.surface
        guard let surfaceModel = surface.surfaceModel else {
            XCTFail("Ghostty surface model failed to initialize")
            return
        }

        let initialMarker = "FTRG-BASE"
        let deltaMarker = "FTRG-DELTA"
        let surfaceGridSize = remoteGridSize(for: surface, minimumColumns: deltaMarker.count + 1, minimumRows: 2)
        let gridSize = RemoteGridSize(columns: surfaceGridSize.columns, rows: surfaceGridSize.rows)
        let keyframe = RemotePaneKeyframe(
            workspaceID: "workspace-1",
            paneID: 7,
            paneGeneration: 3,
            keyframeID: 11,
            gridSize: gridSize,
            rows: remoteGridRows([initialMarker, "READY"], gridSize: gridSize, firstRowVersion: 10),
            cursor: RemoteCursorState(row: 0, column: initialMarker.count, visible: true, shape: .block),
            activeScreen: .primary,
            datagramsEnabledAfterKeyframe: true
        )
        let delta = RemotePaneDelta(
            workspaceID: "workspace-1",
            paneID: 7,
            paneGeneration: 3,
            baseKeyframeID: 11,
            deltaSequence: 1,
            rowUpdates: [
                RemoteRowUpdate(
                    rowIndex: 0,
                    rowVersion: 20,
                    update: .fullRow(remoteGridCells(deltaMarker, columns: gridSize.columns))
                )
            ],
            cursor: RemoteCursorState(row: 0, column: deltaMarker.count, visible: true, shape: .block)
        )
        var state = RemotePaneGridState.empty
        XCTAssertEqual(state.apply(keyframe), .applied)

        let renderer = RemoteGridSurfaceRenderer()
        XCTAssertEqual(renderer.render(state, into: surfaceModel), .rendered)
        try await waitForVisibleText(containing: initialMarker, from: surface)

        XCTAssertEqual(state.apply(delta), .applied)
        XCTAssertEqual(renderer.render(state, into: surfaceModel), .rendered)

        try await waitForVisibleText(containing: deltaMarker, from: surface)
    }

    func testRemoteGridRendererRendersContentWhenCursorShapeIsNotBlock() async throws {
        let fixture = try await makeSurface()
        defer { fixture.cleanUp() }

        let surface = fixture.surface
        guard let surfaceModel = surface.surfaceModel else {
            XCTFail("Ghostty surface model failed to initialize")
            return
        }

        let marker = "FTRG-BAR-CURSOR"
        let surfaceGridSize = remoteGridSize(for: surface, minimumColumns: marker.count + 1, minimumRows: 1)
        let gridSize = RemoteGridSize(columns: surfaceGridSize.columns, rows: surfaceGridSize.rows)
        let keyframe = RemotePaneKeyframe(
            workspaceID: "workspace-1",
            paneID: 7,
            paneGeneration: 3,
            keyframeID: 11,
            gridSize: gridSize,
            rows: remoteGridRows([marker], gridSize: gridSize, firstRowVersion: 10),
            cursor: RemoteCursorState(row: 0, column: marker.count, visible: true, shape: .bar),
            activeScreen: .primary,
            datagramsEnabledAfterKeyframe: true
        )
        var state = RemotePaneGridState.empty
        XCTAssertEqual(state.apply(keyframe), .applied)

        XCTAssertEqual(RemoteGridSurfaceRenderer().render(state, into: surfaceModel), .rendered)

        try await waitForVisibleText(containing: marker, from: surface)
    }

    func testRemoteGridRendererPassesStyledCellsAndCursorShapeToSurface() {
        let gridSize = RemoteGridSize(columns: 3, rows: 1)
        var styled = RemoteCellStyle.normal
        styled.foreground = .indexed(196)
        styled.background = .rgb(red: 12, green: 34, blue: 56)
        styled.bold = true
        styled.italic = true
        styled.underline = .curly
        styled.strikethrough = true

        let keyframe = RemotePaneKeyframe(
            workspaceID: "workspace-1",
            paneID: 7,
            paneGeneration: 3,
            keyframeID: 11,
            gridSize: gridSize,
            rows: [
                RemoteGridRow(index: 0, rowVersion: 10, cells: [
                    .text("A", style: styled),
                    .text("B"),
                    .blank
                ])
            ],
            cursor: RemoteCursorState(row: 0, column: 1, visible: true, shape: .underline),
            activeScreen: .primary,
            datagramsEnabledAfterKeyframe: true
        )
        var state = RemotePaneGridState.empty
        XCTAssertEqual(state.apply(keyframe), .applied)

        let surface = RecordingRemoteGridSurface()
        XCTAssertEqual(RemoteGridSurfaceRenderer().render(state, into: surface), .rendered)

        XCTAssertEqual(surface.resetSizes, [gridSize])
        XCTAssertEqual(surface.rows, [0: keyframe.rows[0].cells])
        XCTAssertEqual(surface.cursor, keyframe.cursor)
    }

    func testRemoteGridRendererFallsBackToPlainTextWhenStructuredRowIsRejected() {
        let gridSize = RemoteGridSize(columns: 3, rows: 1)
        var styled = RemoteCellStyle.normal
        styled.foreground = .indexed(196)
        styled.bold = true

        let keyframe = RemotePaneKeyframe(
            workspaceID: "workspace-1",
            paneID: 7,
            paneGeneration: 3,
            keyframeID: 11,
            gridSize: gridSize,
            rows: [
                RemoteGridRow(index: 0, rowVersion: 10, cells: [
                    .text("A", style: styled),
                    .text("B"),
                    .blank
                ])
            ],
            cursor: RemoteCursorState(row: 0, column: 1, visible: true, shape: .block),
            activeScreen: .primary,
            datagramsEnabledAfterKeyframe: true
        )
        var state = RemotePaneGridState.empty
        XCTAssertEqual(state.apply(keyframe), .applied)

        let surface = RecordingRemoteGridSurface()
        surface.rejectStructuredRows = true
        XCTAssertEqual(RemoteGridSurfaceRenderer().render(state, into: surface), .rendered)

        XCTAssertEqual(surface.textRows, [0: "AB "])
        XCTAssertEqual(surface.cursor, keyframe.cursor)
    }

    func testRemoteGridRendererSanitizesFallbackTextWhenSurfaceRejectsUnknownWidthGlyph() {
        let gridSize = RemoteGridSize(columns: 4, rows: 1)
        let unknownLocalWidthGlyph = "\u{E0B1}"
        let keyframe = RemotePaneKeyframe(
            workspaceID: "workspace-1",
            paneID: 7,
            paneGeneration: 3,
            keyframeID: 11,
            gridSize: gridSize,
            rows: [
                RemoteGridRow(index: 0, rowVersion: 10, cells: [
                    .text(unknownLocalWidthGlyph),
                    .text("O"),
                    .text("K"),
                    .blank
                ])
            ],
            cursor: RemoteCursorState(row: 0, column: 2, visible: true, shape: .block),
            activeScreen: .primary,
            datagramsEnabledAfterKeyframe: true
        )
        var state = RemotePaneGridState.empty
        XCTAssertEqual(state.apply(keyframe), .applied)

        let surface = RecordingRemoteGridSurface()
        surface.rejectStructuredRows = true
        surface.rejectedTextFragments.insert(unknownLocalWidthGlyph)
        XCTAssertEqual(RemoteGridSurfaceRenderer().render(state, into: surface), .rendered)

        XCTAssertEqual(surface.textRows, [0: " OK "])
        XCTAssertEqual(surface.cursor, keyframe.cursor)
    }

    func testRemoteGridRendererReportsRejectedRowStage() {
        let gridSize = RemoteGridSize(columns: 3, rows: 1)
        let keyframe = RemotePaneKeyframe(
            workspaceID: "workspace-1",
            paneID: 7,
            paneGeneration: 3,
            keyframeID: 11,
            gridSize: gridSize,
            rows: [
                RemoteGridRow(index: 0, rowVersion: 10, cells: [
                    .text("A"),
                    .text("B"),
                    .blank
                ])
            ],
            cursor: RemoteCursorState(row: 0, column: 1, visible: true, shape: .block),
            activeScreen: .primary,
            datagramsEnabledAfterKeyframe: true
        )
        var state = RemotePaneGridState.empty
        XCTAssertEqual(state.apply(keyframe), .applied)

        let surface = RecordingRemoteGridSurface()
        surface.rejectStructuredRows = true
        surface.rejectTextRows = true

        let result = RemoteGridSurfaceRenderer().render(state, into: surface)

        XCTAssertEqual(result, .rejectedBySurface)
        XCTAssertEqual(result.rejectionStage, .row(0))
    }

    func testRemoteGridRendererRejectsOversizedGridBeforeMutatingVisibleState() async throws {
        let fixture = try await makeSurface()
        defer { fixture.cleanUp() }

        let surface = fixture.surface
        guard let surfaceModel = surface.surfaceModel else {
            XCTFail("Ghostty surface model failed to initialize")
            return
        }

        let marker = "FTRG-LAST-GOOD"
        let surfaceGridSize = remoteGridSize(for: surface, minimumColumns: marker.count + 1, minimumRows: 1)
        let gridSize = RemoteGridSize(columns: surfaceGridSize.columns, rows: surfaceGridSize.rows)
        XCTAssertTrue(surfaceModel.resetRemoteGrid(columns: gridSize.columns, rows: gridSize.rows))
        XCTAssertTrue(surfaceModel.setRemoteGridRow(0, text: marker))
        try await waitForVisibleText(containing: marker, from: surface)

        let oversizedColumns = 1001
        let invalidKeyframe = RemotePaneKeyframe(
            workspaceID: "workspace-1",
            paneID: 7,
            paneGeneration: 3,
            keyframeID: 11,
            gridSize: RemoteGridSize(columns: oversizedColumns, rows: 1),
            rows: [
                RemoteGridRow(
                    index: 0,
                    rowVersion: 10,
                    cells: Array(repeating: .blank, count: oversizedColumns)
                )
            ],
            cursor: RemoteCursorState(row: 0, column: 0, visible: true, shape: .block),
            activeScreen: .primary,
            datagramsEnabledAfterKeyframe: true
        )
        var state = RemotePaneGridState.empty
        XCTAssertEqual(state.apply(invalidKeyframe), .applied)

        XCTAssertEqual(RemoteGridSurfaceRenderer().render(state, into: surfaceModel), .rejectedBySurface)
        try await waitForVisibleText(containing: marker, from: surface)
    }

    func testRemoteGridRendererRendersStyledCellsToVisibleTerminalState() async throws {
        let fixture = try await makeSurface()
        defer { fixture.cleanUp() }

        let surface = fixture.surface
        guard let surfaceModel = surface.surfaceModel else {
            XCTFail("Ghostty surface model failed to initialize")
            return
        }

        let marker = "FTRG-STYLED"
        let surfaceGridSize = remoteGridSize(for: surface, minimumColumns: marker.count + 1, minimumRows: 1)
        let gridSize = RemoteGridSize(columns: surfaceGridSize.columns, rows: surfaceGridSize.rows)

        var styled = RemoteCellStyle.normal
        styled.foreground = .indexed(196)
        styled.background = .rgb(red: 12, green: 34, blue: 56)
        styled.bold = true
        styled.underline = .single
        let styledCells = marker.map { RemoteGridCell.text(String($0), style: styled) }
        let styledKeyframe = RemotePaneKeyframe(
            workspaceID: "workspace-1",
            paneID: 7,
            paneGeneration: 3,
            keyframeID: 11,
            gridSize: gridSize,
            rows: [
                RemoteGridRow(
                    index: 0,
                    rowVersion: 10,
                    cells: styledCells + Array(repeating: .blank, count: gridSize.columns - styledCells.count)
                )
            ] + (1..<gridSize.rows).map { index in
                RemoteGridRow(index: index, rowVersion: 10 + UInt64(index), cells: remoteGridCells("", columns: gridSize.columns))
            },
            cursor: RemoteCursorState(row: 0, column: 0, visible: true, shape: .block),
            activeScreen: .primary,
            datagramsEnabledAfterKeyframe: true
        )
        var state = RemotePaneGridState.empty
        XCTAssertEqual(state.apply(styledKeyframe), .applied)

        XCTAssertEqual(RemoteGridSurfaceRenderer().render(state, into: surfaceModel), .rendered)
        try await waitForVisibleText(containing: marker, from: surface)
    }

    func testRemoteGridStateRejectsWidthMismatchedCellsBeforeMutatingVisibleState() async throws {
        let fixture = try await makeSurface()
        defer { fixture.cleanUp() }

        let surface = fixture.surface
        guard let surfaceModel = surface.surfaceModel else {
            XCTFail("Ghostty surface model failed to initialize")
            return
        }

        let marker = "FTRG-WIDTH-LAST-GOOD"
        let surfaceGridSize = remoteGridSize(for: surface, minimumColumns: marker.count + 1, minimumRows: 1)
        let gridSize = RemoteGridSize(columns: surfaceGridSize.columns, rows: surfaceGridSize.rows)
        XCTAssertTrue(surfaceModel.resetRemoteGrid(columns: gridSize.columns, rows: gridSize.rows))
        XCTAssertTrue(surfaceModel.setRemoteGridRow(0, text: marker))
        try await waitForVisibleText(containing: marker, from: surface)

        let malformedKeyframe = RemotePaneKeyframe(
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
        var state = RemotePaneGridState.empty
        XCTAssertEqual(state.apply(malformedKeyframe), .needsKeyframe(.malformedKeyframe))

        XCTAssertEqual(RemoteGridSurfaceRenderer().render(state, into: surfaceModel), .notReady)
        try await waitForVisibleText(containing: marker, from: surface)
    }

    func testRemoteGridAcceptsTerminalUnicodeRows() async throws {
        let fixture = try await makeSurface()
        defer { fixture.cleanUp() }

        let surface = fixture.surface
        guard let surfaceModel = surface.surfaceModel else {
            XCTFail("Ghostty surface model failed to initialize")
            return
        }

        let marker = "FTRG-UNICODE"
        let gridSize = remoteGridSize(for: surface, minimumColumns: 40, minimumRows: 1)
        XCTAssertTrue(surfaceModel.resetRemoteGrid(columns: gridSize.columns, rows: gridSize.rows))
        XCTAssertTrue(surfaceModel.setRemoteGridRow(0, text: "\(marker)-e\u{0301}-\u{1F600}\u{FE0F}"))

        try await waitForVisibleText(containing: marker, from: surface)
    }

    func testRemoteGridRejectsInvalidRowsAndOversizedResetWithoutCorruptingState() async throws {
        let fixture = try await makeSurface()
        defer { fixture.cleanUp() }

        let surface = fixture.surface
        guard let surfaceModel = surface.surfaceModel else {
            XCTFail("Ghostty surface model failed to initialize")
            return
        }

        let marker = "FTRG-AFTER-REJECT"
        XCTAssertFalse(surfaceModel.resetRemoteGrid(columns: 1001, rows: 1))
        let gridSize = remoteGridSize(for: surface, minimumColumns: 40, minimumRows: 1)
        XCTAssertTrue(surfaceModel.resetRemoteGrid(columns: gridSize.columns, rows: gridSize.rows))
        XCTAssertFalse(surfaceModel.setRemoteGridRow(0, text: "\u{009B}"))
        XCTAssertFalse(surfaceModel.setRemoteGridRow(0, text: "\u{0301}"))
        XCTAssertFalse(surfaceModel.setRemoteGridCursor(row: gridSize.rows, column: 0, visible: true))
        XCTAssertTrue(surfaceModel.setRemoteGridRow(0, text: marker))

        try await waitForVisibleText(containing: marker, from: surface)
    }

    private struct SurfaceFixture {
        let surface: Fantastty.Ghostty.SurfaceView
        let app: Fantastty.Ghostty.App
        let configURL: URL

        func cleanUp() {
            try? FileManager.default.removeItem(at: configURL)
        }
    }

    private enum SurfaceFixtureError: Error {
        case ghosttyAppInitializationFailed
    }

    private func makeSurface() async throws -> SurfaceFixture {
        let configURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("fantastty-ghostty-remote-grid-\(UUID().uuidString).conf")
        try Data("window-vsync = false\n".utf8).write(to: configURL)

        let app = Fantastty.Ghostty.App(configPath: configURL.path)
        guard let cApp = app.app else {
            throw SurfaceFixtureError.ghosttyAppInitializationFailed
        }

        var config = Fantastty.Ghostty.SurfaceConfiguration()
        config.command = "/bin/cat"
        let surface = Fantastty.Ghostty.SurfaceView(cApp, baseConfig: config)
        try await waitForGhosttySurfaceStartup()
        return SurfaceFixture(surface: surface, app: app, configURL: configURL)
    }

    private func waitForGhosttySurfaceStartup() async throws {
        // Ghostty starts surface IO asynchronously; short-lived XCTest fixtures need
        // startup to settle before teardown.
        try await Task.sleep(nanoseconds: 100_000_000)
    }

    private func remoteGridSize(
        for surfaceView: Fantastty.Ghostty.SurfaceView,
        minimumColumns: Int,
        minimumRows: Int
    ) -> (columns: Int, rows: Int) {
        guard let surface = surfaceView.surface else {
            return (columns: 80, rows: 24)
        }

        let size = ghostty_surface_size(surface)
        let columns = Int(size.columns)
        let rows = Int(size.rows)
        guard columns >= minimumColumns, rows >= minimumRows else {
            return (columns: 80, rows: 24)
        }

        return (columns: columns, rows: rows)
    }

    private func remoteGridCells(_ text: String, columns: Int) -> [RemoteGridCell] {
        var cells = text.map { RemoteGridCell.text(String($0)) }
        while cells.count < columns {
            cells.append(.blank)
        }
        return cells
    }

    private func remoteGridRows(
        _ rowTexts: [String],
        gridSize: RemoteGridSize,
        firstRowVersion: UInt64
    ) -> [RemoteGridRow] {
        (0..<gridSize.rows).map { index in
            RemoteGridRow(
                index: index,
                rowVersion: firstRowVersion + UInt64(index),
                cells: remoteGridCells(rowTexts.indices.contains(index) ? rowTexts[index] : "", columns: gridSize.columns)
            )
        }
    }

    private func waitForVisibleText(
        containing marker: String,
        from surface: Fantastty.Ghostty.SurfaceView
    ) async throws {
        let deadline = Date().addingTimeInterval(3.0)
        var lastVisibleText = ""
        while Date() < deadline {
            lastVisibleText = readVisibleText(from: surface)
            if lastVisibleText.contains(marker) {
                return
            }

            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTFail("Remote-grid marker never appeared in visible terminal text. Last visible text: \(lastVisibleText)")
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

    private final class RecordingRemoteGridSurface: RemoteGridSurface {
        var resetSizes: [RemoteGridSize] = []
        var rows: [Int: [RemoteGridCell]] = [:]
        var textRows: [Int: String] = [:]
        var cursor: RemoteCursorState?
        var rejectStructuredRows = false
        var rejectTextRows = false
        var rejectedTextFragments: Set<String> = []

        func resetRemoteGrid(columns: Int, rows: Int) -> Bool {
            resetSizes.append(RemoteGridSize(columns: columns, rows: rows))
            return true
        }

        func setRemoteGridRow(_ row: Int, text: String) -> Bool {
            guard !rejectTextRows else { return false }
            guard !rejectedTextFragments.contains(where: { text.contains($0) }) else {
                return false
            }
            textRows[row] = text
            return true
        }

        func setRemoteGridRow(_ row: Int, cells: [RemoteGridCell]) -> Bool {
            guard !rejectStructuredRows else { return false }
            rows[row] = cells
            return true
        }

        func setRemoteGridCursor(_ cursor: RemoteCursorState) -> Bool {
            self.cursor = cursor
            return true
        }
    }

}
