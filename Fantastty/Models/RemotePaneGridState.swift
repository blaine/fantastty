import Foundation

enum RemotePaneDeltaDelivery: Equatable, Sendable {
    case reliable
    case datagram
}

struct RemotePaneGridState: Equatable, Sendable {
    private(set) var workspaceID: String?
    private(set) var paneID: Int?
    private(set) var paneGeneration: UInt64?
    private(set) var keyframeID: UInt64?
    private(set) var lastDeltaSequence: UInt64
    private(set) var gridSize: RemoteGridSize?
    private(set) var rows: [[RemoteGridCell]]
    private(set) var rowVersions: [UInt64]
    private(set) var cursor: RemoteCursorState?
    private(set) var activeScreen: RemoteActiveScreen?
    private(set) var tentativeRows: Set<Int>
    private(set) var datagramsEnabledAfterKeyframe: Bool

    static let empty = RemotePaneGridState()

    init() {
        workspaceID = nil
        paneID = nil
        paneGeneration = nil
        keyframeID = nil
        lastDeltaSequence = 0
        gridSize = nil
        rows = []
        rowVersions = []
        cursor = nil
        activeScreen = nil
        tentativeRows = []
        datagramsEnabledAfterKeyframe = false
    }

    mutating func apply(_ keyframe: RemotePaneKeyframe) -> RemotePaneGridApplyResult {
        if let dropReason = dropReason(for: keyframe) {
            return .dropped(dropReason)
        }

        guard validate(keyframe) else {
            return .needsKeyframe(.malformedKeyframe)
        }

        workspaceID = keyframe.workspaceID
        paneID = keyframe.paneID
        paneGeneration = keyframe.paneGeneration
        keyframeID = keyframe.keyframeID
        lastDeltaSequence = 0
        gridSize = keyframe.gridSize
        let sortedRows = keyframe.rows.sorted { $0.index < $1.index }
        rows = sortedRows.map(\.cells)
        rowVersions = sortedRows.map(\.rowVersion)
        cursor = keyframe.cursor
        activeScreen = keyframe.activeScreen
        tentativeRows = []
        datagramsEnabledAfterKeyframe = keyframe.datagramsEnabledAfterKeyframe
        return .applied
    }

    mutating func apply(
        _ delta: RemotePaneDelta,
        delivery: RemotePaneDeltaDelivery = .datagram
    ) -> RemotePaneGridApplyResult {
        guard let workspaceID, let paneID, let paneGeneration, let keyframeID, let gridSize else {
            return .needsKeyframe(.noKeyframe)
        }
        guard delta.workspaceID == workspaceID else {
            return .dropped(.wrongWorkspace)
        }
        guard delta.paneID == paneID else {
            return .dropped(.wrongPane)
        }
        guard delta.paneGeneration == paneGeneration else {
            return delta.paneGeneration < paneGeneration
                ? .dropped(.staleGeneration)
                : .needsKeyframe(.generationMismatch)
        }
        guard delta.baseKeyframeID == keyframeID else {
            return .needsKeyframe(.baseKeyframeMismatch)
        }
        guard delivery == .reliable || datagramsEnabledAfterKeyframe else {
            return .needsKeyframe(.datagramsDisabled)
        }
        guard validate(delta, in: gridSize) else {
            return .needsKeyframe(.malformedDelta)
        }
        guard delta.deltaSequence > lastDeltaSequence || hasUsefulState(delta) else {
            return .dropped(.staleDelta)
        }

        var nextRows = rows
        var nextRowVersions = rowVersions
        for rowUpdate in delta.rowUpdates where rowUpdate.rowVersion > nextRowVersions[rowUpdate.rowIndex] {
            let rowIndex = rowUpdate.rowIndex
            switch rowUpdate.update {
            case .fullRow(let cells):
                nextRows[rowIndex] = cells
            case .span(let baseRowVersion, let startColumn, let cells, let clearToColumn):
                guard baseRowVersion == nextRowVersions[rowIndex] else {
                    return .needsKeyframe(.rowVersionMismatch)
                }
                for offset in cells.indices {
                    nextRows[rowIndex][startColumn + offset] = cells[offset]
                }
                if let clearToColumn {
                    let clearStart = startColumn + cells.count
                    if clearStart < clearToColumn {
                        for column in clearStart..<clearToColumn {
                            nextRows[rowIndex][column] = .blank
                        }
                    }
                }
            }
            guard Self.validateCells(nextRows[rowIndex]) else {
                return .needsKeyframe(.malformedDelta)
            }
            nextRowVersions[rowIndex] = rowUpdate.rowVersion
        }

        if let cursor = delta.cursor,
           cursor.cursorVersion > (self.cursor?.cursorVersion ?? 0) {
            self.cursor = cursor
        }
        rows = nextRows
        rowVersions = nextRowVersions
        tentativeRows = []
        lastDeltaSequence = max(lastDeltaSequence, delta.deltaSequence)
        return .applied
    }

    func displayCopy(applying overlay: RemotePaneOverlay) -> RemotePaneGridState? {
        guard let gridSize else { return nil }
        var copy = self
        var touchedRows = Set<Int>()

        for overlayCell in overlay.cells {
            guard overlayCell.row >= 0,
                  overlayCell.row < gridSize.rows,
                  overlayCell.column >= 0,
                  overlayCell.column < gridSize.columns else {
                return nil
            }
            copy.rows[overlayCell.row][overlayCell.column] = overlayCell.cell
            touchedRows.insert(overlayCell.row)
        }

        for row in touchedRows {
            guard Self.validateCells(copy.rows[row]) else { return nil }
        }

        if let cursor = overlay.cursor {
            guard validateCursor(cursor, in: gridSize) else { return nil }
            copy.cursor = cursor
        }

        copy.tentativeRows = touchedRows
        return copy
    }

    private func dropReason(for keyframe: RemotePaneKeyframe) -> RemotePaneGridDropReason? {
        if let workspaceID, keyframe.workspaceID != workspaceID {
            return .wrongWorkspace
        }
        if let paneID, keyframe.paneID != paneID {
            return .wrongPane
        }
        if let paneGeneration {
            if keyframe.paneGeneration < paneGeneration {
                return .staleGeneration
            }
            if keyframe.paneGeneration == paneGeneration,
               let currentKeyframeID = keyframeID,
               keyframe.keyframeID <= currentKeyframeID {
                return .staleKeyframe
            }
        }
        return nil
    }

    private func validate(_ keyframe: RemotePaneKeyframe) -> Bool {
        guard keyframe.gridSize.columns > 0, keyframe.gridSize.rows > 0 else {
            return false
        }
        guard keyframe.rows.count == keyframe.gridSize.rows else {
            return false
        }
        var seenRows = Set<Int>()
        for row in keyframe.rows {
            guard row.index >= 0, row.index < keyframe.gridSize.rows else {
                return false
            }
            guard seenRows.insert(row.index).inserted else {
                return false
            }
            guard row.cells.count == keyframe.gridSize.columns else {
                return false
            }
            guard Self.validateCells(row.cells) else {
                return false
            }
        }
        return validateCursor(keyframe.cursor, in: keyframe.gridSize)
    }
}

enum RemotePaneGridApplyResult: Equatable, Sendable {
    case applied
    case dropped(RemotePaneGridDropReason)
    case needsKeyframe(RemotePaneGridKeyframeRequestReason)
}

enum RemotePaneGridDropReason: Equatable, Sendable {
    case staleKeyframe
    case wrongWorkspace
    case wrongPane
    case staleGeneration
    case staleDelta
}

enum RemotePaneGridKeyframeRequestReason: Equatable, Sendable {
    case noKeyframe
    case baseKeyframeMismatch
    case generationMismatch
    case rowVersionMismatch
    case datagramsDisabled
    case malformedKeyframe
    case malformedDelta
    case resizeMismatch
}

private extension RemotePaneGridState {
    static func validateCells(_ cells: [RemoteGridCell]) -> Bool {
        var index = 0
        while index < cells.count {
            let cell = cells[index]
            guard RemoteGridTextMetrics.displayWidth(
                of: cell.text,
                maximumColumns: cells.count
            ) == cell.width else {
                return false
            }
            switch cell.width {
            case 1:
                index += 1
            case 2:
                let continuationIndex = index + 1
                guard continuationIndex < cells.count else { return false }
                guard cells[continuationIndex] == .continuation else { return false }
                index += 2
            default:
                return false
            }
        }
        return true
    }

    func validateCursor(_ cursor: RemoteCursorState, in size: RemoteGridSize) -> Bool {
        cursor.row >= 0 &&
        cursor.row < size.rows &&
        cursor.column >= 0 &&
        cursor.column < size.columns &&
        cursor.cursorVersion > 0
    }

    func hasUsefulState(_ delta: RemotePaneDelta) -> Bool {
        if delta.rowUpdates.contains(where: { $0.rowVersion > rowVersions[$0.rowIndex] }) {
            return true
        }
        if let cursor = delta.cursor,
           cursor.cursorVersion > (self.cursor?.cursorVersion ?? 0) {
            return true
        }
        return false
    }

    func validate(_ delta: RemotePaneDelta, in size: RemoteGridSize) -> Bool {
        var seenRows = Set<Int>()
        for rowUpdate in delta.rowUpdates {
            guard rowUpdate.rowIndex >= 0, rowUpdate.rowIndex < size.rows else {
                return false
            }
            guard seenRows.insert(rowUpdate.rowIndex).inserted else {
                return false
            }
            switch rowUpdate.update {
            case .fullRow(let cells):
                guard cells.count == size.columns else {
                    return false
                }
                guard Self.validateCells(cells) else {
                    return false
                }
            case .span(_, let startColumn, let cells, let clearToColumn):
                guard startColumn >= 0, startColumn < size.columns else {
                    return false
                }
                guard !cells.isEmpty else {
                    return false
                }
                guard cells.count <= size.columns - startColumn else {
                    return false
                }
                let spanEnd = startColumn + cells.count
                if let clearToColumn {
                    guard clearToColumn >= spanEnd else {
                        return false
                    }
                    guard clearToColumn <= size.columns else {
                        return false
                    }
                }
                guard Self.validateCells(cells) else {
                    return false
                }
            }
        }
        if let cursor = delta.cursor {
            guard validateCursor(cursor, in: size) else {
                return false
            }
        }
        return true
    }
}
