import Foundation

@MainActor
protocol RemoteGridSurface: AnyObject {
    func resetRemoteGrid(columns: Int, rows: Int) -> Bool
    func setRemoteGridRow(_ row: Int, text: String) -> Bool
    func setRemoteGridRow(_ row: Int, cells: [RemoteGridCell]) -> Bool
    func setRemoteGridCursor(_ cursor: RemoteCursorState) -> Bool
}

struct RemoteGridSurfaceRenderer {
    private let maxColumns = 1000
    private let maxRows = 1000
    private let maxCells = 250_000
    private let maxRowBytes = 4096

    @MainActor
    func render(
        _ state: RemotePaneGridState,
        into surface: RemoteGridSurface,
        resetGrid: Bool = true,
        rowsToRender: Set<Int>? = nil
    ) -> RemoteGridSurfaceRenderResult {
        guard let size = state.gridSize else {
            return .notReady
        }
        guard let plan = renderPlan(from: state, size: size) else {
            return .rejectedBySurface(stage: .renderPlan)
        }
        if resetGrid {
            guard surface.resetRemoteGrid(columns: size.columns, rows: size.rows) else {
                return .rejectedBySurface(stage: .resetGrid)
            }
        }

        let renderedRows = rowsToRender ?? Set(plan.rows.indices)
        for rowIndex in plan.rows.indices where renderedRows.contains(rowIndex) {
            let row = plan.rows[rowIndex]
            if state.tentativeRows.contains(rowIndex) {
                guard surface.setRemoteGridRow(rowIndex, cells: row) else {
                    return .rejectedBySurface(stage: .row(rowIndex))
                }
                continue
            }
            guard surface.setRemoteGridRow(rowIndex, cells: row) ||
                  surface.setRemoteGridRow(rowIndex, text: plainText(from: row)) ||
                  surface.setRemoteGridRow(rowIndex, text: sanitizedPlainText(from: row)) else {
                return .rejectedBySurface(stage: .row(rowIndex))
            }
        }

        if let cursor = plan.cursor {
            guard surface.setRemoteGridCursor(cursor) else {
                return .rejectedBySurface(stage: .cursor)
            }
        }
        return .rendered
    }

    private func renderPlan(
        from state: RemotePaneGridState,
        size: RemoteGridSize
    ) -> RemoteGridSurfaceRenderPlan? {
        guard size.columns > 0, size.rows > 0 else { return nil }
        guard size.columns <= maxColumns, size.rows <= maxRows else { return nil }
        guard size.columns * size.rows <= maxCells else { return nil }
        guard state.rows.count == size.rows else { return nil }

        let rows = state.rows.map { rowCells(from: $0, columns: size.columns) }
        guard rows.allSatisfy({ $0 != nil }) else { return nil }

        if let cursor = state.cursor {
            guard cursor.row >= 0, cursor.row < size.rows else { return nil }
            guard cursor.column >= 0, cursor.column < size.columns else { return nil }
        }

        return RemoteGridSurfaceRenderPlan(rows: rows.compactMap { $0 }, cursor: state.cursor)
    }

    private func rowCells(from cells: [RemoteGridCell], columns: Int) -> [RemoteGridCell]? {
        var byteCount = 0
        var displayWidth = 0

        for cell in cells {
            guard cell.width >= 0 else { return nil }
            guard !RemoteGridTextMetrics.containsControlScalars(cell.text) else { return nil }

            byteCount += cell.text.utf8.count
            guard byteCount <= maxRowBytes else { return nil }
            displayWidth += cell.width
            guard displayWidth <= columns else { return nil }
        }

        guard displayWidth == columns else { return nil }
        return cells
    }

    private func plainText(from cells: [RemoteGridCell]) -> String {
        cells.map(\.text).joined()
    }

    private func sanitizedPlainText(from cells: [RemoteGridCell]) -> String {
        cells.map { cell in
            guard cell.width > 0 else { return "" }
            guard isPrintableASCII(cell.text),
                  RemoteGridTextMetrics.displayWidth(
                      of: cell.text,
                      maximumColumns: cell.width
                  ) == cell.width else {
                return String(repeating: " ", count: cell.width)
            }
            return cell.text
        }.joined()
    }

    private func isPrintableASCII(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy { scalar in
            scalar.value >= 0x20 && scalar.value <= 0x7E
        }
    }
}

struct RemoteGridSurfaceRenderResult: Equatable, CustomStringConvertible {
    enum Status: Equatable {
        case rendered
        case notReady
        case rejectedBySurface
    }

    enum RejectionStage: Equatable, CustomStringConvertible {
        case renderPlan
        case resetGrid
        case row(Int)
        case cursor

        var description: String {
            switch self {
            case .renderPlan:
                return "renderPlan"
            case .resetGrid:
                return "resetGrid"
            case .row(let rowIndex):
                return "row(\(rowIndex))"
            case .cursor:
                return "cursor"
            }
        }
    }

    let status: Status
    let rejectionStage: RejectionStage?

    static let rendered = RemoteGridSurfaceRenderResult(status: .rendered, rejectionStage: nil)
    static let notReady = RemoteGridSurfaceRenderResult(status: .notReady, rejectionStage: nil)
    static let rejectedBySurface = RemoteGridSurfaceRenderResult(
        status: .rejectedBySurface,
        rejectionStage: nil
    )

    static func rejectedBySurface(stage: RejectionStage) -> RemoteGridSurfaceRenderResult {
        RemoteGridSurfaceRenderResult(status: .rejectedBySurface, rejectionStage: stage)
    }

    static func == (lhs: RemoteGridSurfaceRenderResult, rhs: RemoteGridSurfaceRenderResult) -> Bool {
        guard lhs.status == rhs.status else { return false }
        guard lhs.status == .rejectedBySurface else { return true }
        if lhs.rejectionStage == nil || rhs.rejectionStage == nil {
            return true
        }
        return lhs.rejectionStage == rhs.rejectionStage
    }

    var description: String {
        switch status {
        case .rendered:
            return "rendered"
        case .notReady:
            return "notReady"
        case .rejectedBySurface:
            if let rejectionStage {
                return "rejectedBySurface(\(rejectionStage))"
            }
            return "rejectedBySurface"
        }
    }
}

private struct RemoteGridSurfaceRenderPlan {
    let rows: [[RemoteGridCell]]
    let cursor: RemoteCursorState?
}
