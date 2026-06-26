import Foundation

struct RemotePaneInput: Equatable, Sendable {
    let data: Data
    let source: RemotePaneInputSource

    var predictionEligible: Bool {
        source == .directKey || source == .plainEraseByte
    }
}

enum RemotePaneInputSource: Equatable, Sendable {
    case directKey
    case plainEraseByte
    case paste
    case imeCommit
    case escapeSequence
    case mouse
    case localBinding
}

extension RemotePaneInputSource {
    static func directInputSource(for data: Data) -> RemotePaneInputSource {
        guard data.count == 1, let byte = data.first else { return .directKey }
        return byte == 0x7F || byte == 0x08 ? .plainEraseByte : .directKey
    }
}

enum RemotePredictionInputResult: Equatable, Sendable {
    case accepted
    case hiddenPendingEcho
    case forwardOnly
    case rejected
}

struct RemotePaneOverlay: Equatable, Sendable {
    let cells: [RemotePaneOverlayCell]
    let cursor: RemoteCursorState?

    static let empty = RemotePaneOverlay(cells: [], cursor: nil)
}

struct RemotePaneOverlayCell: Equatable, Sendable {
    let row: Int
    let column: Int
    let cell: RemoteGridCell
}

struct RemotePredictionEpoch: Equatable, Sendable {
    let workspaceID: String
    let paneID: Int
    let paneGeneration: UInt64
    let keyframeID: UInt64
    let cursorVersion: UInt64
    let gridSize: RemoteGridSize
    let activeScreen: RemoteActiveScreen
}

enum RemotePredictionClearReason: Equatable, Sendable {
    case unsafeAuthoritativeState
    case epochChanged
    case disabledByUser
    case focusLost
    case resize
    case reattach
    case mismatch
}

protocol RemotePredictionTimer: AnyObject {
    func cancel()
}

final class DispatchRemotePredictionTimer: RemotePredictionTimer {
    private var cancelled = false

    func cancel() {
        cancelled = true
    }

    func fire(_ callback: @escaping @MainActor () -> Void) {
        guard !cancelled else { return }
        Task { @MainActor [weak self] in
            guard self?.cancelled == false else { return }
            callback()
        }
    }
}

struct RemotePredictiveEchoEngine: CustomStringConvertible {
    static let defaultLatencyThreshold: TimeInterval = 0.05
    static let defaultNoAckTimeout: TimeInterval = 0.25
    static let defaultCooldownDuration: TimeInterval = 0.5

    private let latencyThreshold: TimeInterval
    private let noAckTimeout: TimeInterval
    private let cooldownDuration: TimeInterval

    private var currentState: RemotePaneGridState?
    private var currentEpoch: RemotePredictionEpoch?
    private var hiddenPending: PendingPrediction?
    private var visiblePending: [PendingPrediction]
    private var erasedPending: [ErasedPendingPrediction]
    private var echoConfidence: Bool
    private var cooldownUntil: TimeInterval?
    private var lastInputTime: TimeInterval?
    private(set) var lastClearReason: RemotePredictionClearReason?

    init(
        latencyThreshold: TimeInterval = Self.defaultLatencyThreshold,
        noAckTimeout: TimeInterval = Self.defaultNoAckTimeout,
        cooldownDuration: TimeInterval = Self.defaultCooldownDuration
    ) {
        self.latencyThreshold = latencyThreshold
        self.noAckTimeout = noAckTimeout
        self.cooldownDuration = cooldownDuration
        currentState = nil
        currentEpoch = nil
        hiddenPending = nil
        visiblePending = []
        erasedPending = []
        echoConfidence = false
        cooldownUntil = nil
        lastInputTime = nil
        lastClearReason = nil
    }

    var hasEchoConfidence: Bool {
        echoConfidence
    }

    var needsKeyframeRequest: Bool {
        false
    }

    var description: String {
        "RemotePredictiveEchoEngine(" +
        "hasEchoConfidence: \(echoConfidence), " +
        "hiddenPending: \(hiddenPending != nil), " +
        "visiblePendingCount: \(visiblePending.count), " +
        "erasedPendingCount: \(erasedPending.count), " +
        "coolingDown: \(cooldownUntil != nil), " +
        "needsKeyframeRequest: false)"
    }

    #if DEBUG
    var debugPendingTextForTests: String? {
        hiddenPending?.text
    }
    #endif

    mutating func observeAuthoritativeState(_ state: RemotePaneGridState) {
        observeAuthoritativeState(state, mismatchObservedAt: nil)
    }

    mutating func observeAuthoritativeState(_ state: RemotePaneGridState, now: TimeInterval) {
        observeAuthoritativeState(state, mismatchObservedAt: now)
    }

    private mutating func observeAuthoritativeState(
        _ state: RemotePaneGridState,
        mismatchObservedAt: TimeInterval?
    ) {
        lastClearReason = nil
        if let mismatchObservedAt {
            expireTimers(now: mismatchObservedAt)
        }

        guard let nextEpoch = Self.predictionEpoch(for: state) else {
            clear(reason: .unsafeAuthoritativeState)
            return
        }

        guard let previousEpoch = currentEpoch else {
            cooldownUntil = nil
            currentState = state
            currentEpoch = nextEpoch
            return
        }

        guard previousEpoch.hardIdentity == nextEpoch.hardIdentity else {
            clearPredictionState()
            cooldownUntil = nil
            currentState = state
            currentEpoch = nextEpoch
            return
        }

        if mismatchObservedAt == nil, hasPendingPredictions {
            currentState = state
            currentEpoch = nextEpoch
            clear(reason: .mismatch, now: nil)
            return
        }

        guard nextEpoch.cursorVersion >= previousEpoch.cursorVersion else {
            return
        }

        if let hiddenPending {
            reconcileHiddenPending(
                hiddenPending,
                with: state,
                nextEpoch: nextEpoch,
                mismatchObservedAt: mismatchObservedAt
            )
            return
        }

        if !visiblePending.isEmpty || !erasedPending.isEmpty {
            reconcileVisiblePending(
                with: state,
                nextEpoch: nextEpoch,
                mismatchObservedAt: mismatchObservedAt
            )
            return
        }

        if authoritativeCursorLineChanged(from: currentState, to: state) ||
            authoritativeCursorRowTextOrWidthChanged(from: currentState, to: state) {
            clearPredictionState()
        }
        currentState = state
        currentEpoch = nextEpoch
    }

    mutating func observeLocalInput(
        _ input: RemotePaneInput,
        now: TimeInterval
    ) -> RemotePredictionInputResult {
        lastClearReason = nil
        expireTimers(now: now)
        lastInputTime = now

        guard !isCoolingDown(now: now) else {
            return .forwardOnly
        }
        guard input.predictionEligible else {
            suppressPredictionsUntilAuthoritativeState()
            return .forwardOnly
        }
        guard let state = currentState,
              currentEpoch != nil,
              let cursor = state.cursor,
              let gridSize = state.gridSize,
              state.activeScreen == .primary,
              cursor.visible else {
            suppressPredictionsUntilAuthoritativeState()
            return .forwardOnly
        }

        switch input.source {
        case .directKey:
            return observeDirectKey(input, cursor: cursor, gridSize: gridSize, now: now)
        case .plainEraseByte:
            return observePlainErase(input, now: now)
        case .paste, .imeCommit, .escapeSequence, .mouse, .localBinding:
            return .forwardOnly
        }
    }

    func diagnosticSuppressionReason(
        for input: RemotePaneInput,
        now: TimeInterval
    ) -> RemoteEngineDiagnosticPredictionSuppressionReason? {
        guard !isCoolingDown(now: now) else {
            return .echoOffOrNoOutput
        }
        guard input.predictionEligible else {
            return Self.diagnosticSuppressionReason(for: input.source)
        }
        guard let state = currentState, currentEpoch != nil else {
            return .unsupportedState
        }
        guard state.activeScreen == .primary else {
            return .alternateScreen
        }
        guard let cursor = state.cursor, let gridSize = state.gridSize else {
            return .echoOffOrNoOutput
        }
        guard cursor.visible else {
            return .echoOffOrNoOutput
        }

        switch input.source {
        case .directKey:
            let position = nextPredictionPosition(cursor: cursor)
            guard position.row >= 0,
                  position.row < gridSize.rows,
                  position.column >= 0,
                  position.column < gridSize.columns else {
                return .unsupportedState
            }
            guard echoConfidence || hiddenPending == nil else {
                return .echoNotProven
            }
            guard erasedPending.isEmpty else {
                return .unsupportedState
            }
            return nil
        case .plainEraseByte:
            guard echoConfidence else {
                return .echoNotProven
            }
            guard !visiblePending.isEmpty else {
                return .unsupportedState
            }
            return nil
        case .paste, .imeCommit, .escapeSequence, .mouse, .localBinding:
            return Self.diagnosticSuppressionReason(for: input.source)
        }
    }

    private static func diagnosticSuppressionReason(
        for source: RemotePaneInputSource
    ) -> RemoteEngineDiagnosticPredictionSuppressionReason {
        switch source {
        case .paste:
            return .paste
        case .imeCommit:
            return .ime
        case .escapeSequence:
            return .escapeSequence
        case .mouse:
            return .mouse
        case .directKey, .plainEraseByte, .localBinding:
            return .unsupportedState
        }
    }

    mutating func expireTimers(now: TimeInterval) {
        if let hiddenPending,
           now - hiddenPending.createdAt >= noAckTimeout {
            clearPredictionState()
            startCooldown(now: now)
            return
        }

        if let firstVisible = visiblePending.first,
           now - firstVisible.createdAt >= noAckTimeout {
            clearPredictionState()
            startCooldown(now: now)
            return
        }

        let oldestErased = erasedPending.min(by: {
            $0.prediction.createdAt < $1.prediction.createdAt
        })?.prediction
        if let oldestErased,
           now - oldestErased.createdAt >= noAckTimeout {
            clearPredictionState()
            startCooldown(now: now)
            return
        }

        if let cooldownUntil, now >= cooldownUntil {
            self.cooldownUntil = nil
        }
    }

    func visibleOverlay(now: TimeInterval) -> RemotePaneOverlay {
        guard echoConfidence, !isCoolingDown(now: now) else {
            return .empty
        }

        var visible: [PendingPrediction] = []
        for pending in visiblePending {
            let age = now - pending.createdAt
            guard age < noAckTimeout else {
                return .empty
            }
            guard age >= latencyThreshold else {
                break
            }
            visible.append(pending)
        }
        guard !visible.isEmpty else {
            return .empty
        }

        return RemotePaneOverlay(
            cells: visible.flatMap { overlayCells(for: $0) },
            cursor: overlayCursor(after: visible)
        )
    }

    func nextOverlayDeadline(now: TimeInterval) -> TimeInterval? {
        guard echoConfidence, !isCoolingDown(now: now) else {
            return nil
        }

        var firstNoAckDeadline: TimeInterval?
        for pending in visiblePending {
            let age = now - pending.createdAt
            guard age < noAckTimeout else {
                return now
            }
            let noAckDeadline = pending.createdAt + noAckTimeout
            firstNoAckDeadline = min(firstNoAckDeadline ?? noAckDeadline, noAckDeadline)
            if age < latencyThreshold {
                return pending.createdAt + latencyThreshold
            }
        }
        return firstNoAckDeadline
    }

    mutating func clear(reason: RemotePredictionClearReason) {
        clear(reason: reason, now: nil)
    }

    private mutating func clear(reason: RemotePredictionClearReason, now: TimeInterval?) {
        lastClearReason = reason
        clearPredictionState()
        switch reason {
        case .mismatch:
            if let now {
                startCooldown(now: now)
            } else {
                startFailClosedCooldown()
            }
        case .unsafeAuthoritativeState, .epochChanged, .disabledByUser, .focusLost, .resize, .reattach:
            cooldownUntil = nil
            currentState = nil
            currentEpoch = nil
        }
    }

    func isCoolingDown(now: TimeInterval) -> Bool {
        guard let cooldownUntil else {
            return false
        }
        return now < cooldownUntil
    }
}

private extension RemotePredictiveEchoEngine {
    struct PendingPrediction: Equatable, Sendable {
        let text: String
        let width: Int
        let row: Int
        let column: Int
        let cell: RemoteGridCell
        let baselineCell: RemoteGridCell?
        let baselineCursor: CursorProofBaseline
        let createdAt: TimeInterval
    }

    struct ErasedPendingPrediction: Equatable, Sendable {
        let prediction: PendingPrediction
    }

    struct PrintableInput: Equatable, Sendable {
        let text: String
        let width: Int
    }

    struct CursorProofBaseline: Equatable, Sendable {
        let row: Int
        let column: Int
        let cursorVersion: UInt64
    }

    enum PendingClassification: Equatable, Sendable {
        case proven
        case stillPending
        case contradicted
    }

    enum VisiblePendingRunClassification: Equatable, Sendable {
        case provenPrefix(Int)
        case stillPending
        case contradicted
    }

    struct PredictionHardIdentity: Equatable, Sendable {
        let workspaceID: String
        let paneID: Int
        let paneGeneration: UInt64
        let keyframeID: UInt64
        let gridSize: RemoteGridSize
        let activeScreen: RemoteActiveScreen
    }

    static func predictionEpoch(for state: RemotePaneGridState) -> RemotePredictionEpoch? {
        guard let workspaceID = state.workspaceID,
              let paneID = state.paneID,
              let paneGeneration = state.paneGeneration,
              let keyframeID = state.keyframeID,
              let gridSize = state.gridSize,
              let cursor = state.cursor,
              let activeScreen = state.activeScreen,
              activeScreen == .primary,
              cursor.visible else {
            return nil
        }

        return RemotePredictionEpoch(
            workspaceID: workspaceID,
            paneID: paneID,
            paneGeneration: paneGeneration,
            keyframeID: keyframeID,
            cursorVersion: cursor.cursorVersion,
            gridSize: gridSize,
            activeScreen: activeScreen
        )
    }

    mutating func reconcileHiddenPending(
        _ pending: PendingPrediction,
        with state: RemotePaneGridState,
        nextEpoch: RemotePredictionEpoch,
        mismatchObservedAt: TimeInterval?
    ) {
        if authoritativeCursorRowTextOrWidthChanged(
            from: currentState,
            to: state,
            excluding: [predictionSpan(for: pending)]
        ) {
            currentState = state
            currentEpoch = nextEpoch
            clear(reason: .mismatch, now: mismatchObservedAt)
            return
        }

        switch classifyPendingPrediction(pending, in: state) {
        case .proven:
            hiddenPending = nil
            echoConfidence = true
            currentState = state
            currentEpoch = nextEpoch
            return
        case .contradicted:
            currentState = state
            currentEpoch = nextEpoch
            clear(reason: .mismatch, now: mismatchObservedAt)
            return
        case .stillPending:
            currentState = state
            currentEpoch = nextEpoch
        }
    }

    mutating func reconcileVisiblePending(
        with state: RemotePaneGridState,
        nextEpoch: RemotePredictionEpoch,
        mismatchObservedAt: TimeInterval?
    ) {
        if authoritativeCursorRowTextOrWidthChanged(
            from: currentState,
            to: state,
            excluding: visiblePending.map { predictionSpan(for: $0) } +
                erasedPending.map { predictionSpan(for: $0.prediction) }
        ) {
            currentState = state
            currentEpoch = nextEpoch
            clear(reason: .mismatch, now: mismatchObservedAt)
            return
        }

        switch classifyVisiblePendingRun(in: state) {
        case .contradicted:
            currentState = state
            currentEpoch = nextEpoch
            clear(reason: .mismatch, now: mismatchObservedAt)
            return
        case .provenPrefix(let count):
            visiblePending.removeFirst(count)
        case .stillPending:
            break
        }

        reconcileErasedPending(in: state)
        currentState = state
        currentEpoch = nextEpoch
        echoConfidence = true
    }

    mutating func observeDirectKey(
        _ input: RemotePaneInput,
        cursor: RemoteCursorState,
        gridSize: RemoteGridSize,
        now: TimeInterval
    ) -> RemotePredictionInputResult {
        let position = nextPredictionPosition(cursor: cursor)
        guard position.row >= 0,
              position.row < gridSize.rows,
              position.column >= 0,
              position.column < gridSize.columns else {
            suppressPredictionsUntilAuthoritativeState()
            return .rejected
        }

        let maximumColumns = gridSize.columns - position.column
        guard let printable = printableInput(from: input.data, maximumColumns: maximumColumns) else {
            suppressPredictionsUntilAuthoritativeState()
            return .rejected
        }

        guard echoConfidence || hiddenPending == nil else {
            clearPredictionState()
            startCooldown(now: now)
            return .forwardOnly
        }

        guard erasedPending.isEmpty else {
            suppressPredictionsUntilAuthoritativeState()
            return .forwardOnly
        }

        guard position.column + printable.width < gridSize.columns else {
            suppressPredictionsUntilAuthoritativeState()
            return .rejected
        }

        guard overlayPreservesAuthoritativeCellBoundaries(
            row: position.row,
            column: position.column,
            width: printable.width
        ) else {
            suppressPredictionsUntilAuthoritativeState()
            return .rejected
        }

        let pending = PendingPrediction(
            text: printable.text,
            width: printable.width,
            row: position.row,
            column: position.column,
            cell: Self.tentativeCell(
                text: printable.text,
                width: printable.width,
                baseStyle: baselineStyle(row: position.row, column: position.column)
            ),
            baselineCell: baselineCell(row: position.row, column: position.column),
            baselineCursor: CursorProofBaseline(
                row: position.row,
                column: position.column,
                cursorVersion: cursor.cursorVersion
            ),
            createdAt: now
        )

        guard echoConfidence else {
            if hiddenPending == nil {
                hiddenPending = pending
                return .hiddenPendingEcho
            }
            return .forwardOnly
        }

        visiblePending.append(pending)
        return .accepted
    }

    mutating func observePlainErase(
        _ input: RemotePaneInput,
        now: TimeInterval
    ) -> RemotePredictionInputResult {
        guard input.data.count == 1,
              let byte = input.data.first,
              byte == 0x7F || byte == 0x08 else {
            suppressPredictionsUntilAuthoritativeState()
            return .rejected
        }

        guard echoConfidence else {
            suppressPredictionsUntilAuthoritativeState()
            return .forwardOnly
        }

        guard !visiblePending.isEmpty else {
            suppressPredictionsUntilAuthoritativeState()
            return .forwardOnly
        }

        let erased = visiblePending.removeLast()
        erasedPending.append(ErasedPendingPrediction(prediction: erased))
        return .accepted
    }

    func printableInput(from data: Data, maximumColumns: Int) -> PrintableInput? {
        guard !data.contains(0x1B),
              let text = String(data: data, encoding: .utf8),
              text.count == 1,
              !RemoteGridTextMetrics.containsControlScalars(text),
              let width = RemoteGridTextMetrics.displayWidth(
                of: text,
                maximumColumns: maximumColumns
              ),
              width == 1 || width == 2 else {
            return nil
        }

        return PrintableInput(text: text, width: width)
    }

    func overlayPreservesAuthoritativeCellBoundaries(row: Int, column: Int, width: Int) -> Bool {
        guard width > 0,
              let rowCells = rowCells(in: currentState, row: row),
              column >= 0,
              column + width <= rowCells.count,
              rowCells[column].width > 0 else {
            return false
        }

        let overlayStart = column
        let overlayEnd = column + width
        for (cellStart, cell) in rowCells.enumerated() where cell.width == 2 {
            let cellEnd = cellStart + cell.width
            guard cellStart < overlayEnd, cellEnd > overlayStart else {
                continue
            }
            if overlayStart > cellStart || overlayEnd < cellEnd {
                return false
            }
        }
        return true
    }

    func nextPredictionPosition(cursor: RemoteCursorState) -> (row: Int, column: Int) {
        guard let last = visiblePending.last else {
            return (cursor.row, cursor.column)
        }
        return (last.row, last.column + last.width)
    }

    func authoritativeState(
        _ state: RemotePaneGridState,
        matches pending: PendingPrediction
    ) -> Bool {
        guard let cell = cell(in: state, row: pending.row, column: pending.column) else {
            return false
        }
        return cell.text == pending.text && cell.width == pending.width
    }

    func authoritativeTextOrWidthChanged(
        in state: RemotePaneGridState,
        at pending: PendingPrediction
    ) -> Bool {
        let next = cell(in: state, row: pending.row, column: pending.column)
        return next?.text != pending.baselineCell?.text ||
            next?.width != pending.baselineCell?.width
    }

    func classifyPendingPrediction(
        _ pending: PendingPrediction,
        in state: RemotePaneGridState
    ) -> PendingClassification {
        let textMatches = authoritativeState(state, matches: pending)
        let textOrWidthChanged = authoritativeTextOrWidthChanged(in: state, at: pending)
        if textOrWidthChanged, !textMatches {
            return .contradicted
        }
        if authoritativeCursorContradictsPendingInput(pending, in: state) {
            return .contradicted
        }
        if authoritativeCursor(in: state, advancedPast: pending) {
            guard textOrWidthChanged else {
                return textMatches ? .stillPending : .contradicted
            }
            return textMatches ? .proven : .contradicted
        }
        return .stillPending
    }

    func classifyVisiblePendingRun(in state: RemotePaneGridState) -> VisiblePendingRunClassification {
        guard !visiblePending.isEmpty else {
            return .stillPending
        }

        if visiblePending.contains(where: {
            authoritativeTextOrWidthChanged(in: state, at: $0) &&
                !authoritativeState(state, matches: $0)
        }) {
            return .contradicted
        }

        if visiblePending.contains(where: {
            authoritativeCursor(in: state, advancedPast: $0) &&
                !authoritativeState(state, matches: $0)
        }) {
            return .contradicted
        }

        let matchingPrefixCount = visiblePending.prefix {
            authoritativeState(state, matches: $0)
        }.count

        if matchingPrefixCount > 0 {
            for count in stride(from: matchingPrefixCount, through: 1, by: -1) {
                if authoritativeCursor(in: state, advancedPast: visiblePending[count - 1]) ||
                    authoritativeCursor(in: state, advancedPastErasedTailAfter: visiblePending[count - 1]) {
                    return .provenPrefix(count)
                }
            }

            let pendingPrefix = visiblePending.prefix(matchingPrefixCount)
            return authoritativeCursorContradictsPendingPrefix(pendingPrefix, in: state) ?
                .contradicted :
                .stillPending
        }

        if visiblePending.contains(where: { authoritativeCursorContradictsPendingInput($0, in: state) }) {
            return .contradicted
        }

        return .stillPending
    }

    mutating func reconcileErasedPending(in state: RemotePaneGridState) {
        var remaining: [ErasedPendingPrediction] = []

        for erased in erasedPending {
            if authoritativeState(state, matches: erased.prediction) {
                remaining.append(erased)
                continue
            }

            if authoritativeEraseProcessed(erased.prediction, in: state) {
                continue
            }

            remaining.append(erased)
        }

        erasedPending = remaining
    }

    func authoritativeEraseProcessed(
        _ pending: PendingPrediction,
        in state: RemotePaneGridState
    ) -> Bool {
        guard let cursor = state.cursor,
              cursor.cursorVersion > pending.baselineCursor.cursorVersion,
              cursor.row == pending.row,
              cursor.column <= pending.column else {
            return false
        }

        return !authoritativeState(state, matches: pending)
    }

    func authoritativeCursorContradictsPendingPrefix(
        _ prefix: ArraySlice<PendingPrediction>,
        in state: RemotePaneGridState
    ) -> Bool {
        guard let first = prefix.first,
              let last = prefix.last,
              let cursor = state.cursor,
              cursor.cursorVersion > first.baselineCursor.cursorVersion else {
            return false
        }

        guard cursor.row == first.row else {
            return true
        }

        let lowestExpectedColumn = min(first.baselineCursor.column, first.column)
        let highestExpectedColumn = highestExpectedColumnAfterErasedTail(
            startingAt: last.column + last.width,
            row: last.row,
            in: state
        )
        return cursor.column < lowestExpectedColumn ||
            cursor.column > highestExpectedColumn
    }

    func authoritativeCursor(
        in state: RemotePaneGridState,
        advancedPastErasedTailAfter pending: PendingPrediction
    ) -> Bool {
        guard let cursor = state.cursor,
              cursor.cursorVersion > pending.baselineCursor.cursorVersion,
              cursor.row == pending.row else {
            return false
        }

        var expectedColumn = pending.column + pending.width
        let consumedErasedTail: Bool
        (expectedColumn, consumedErasedTail) = authoritativeErasedTailEndColumn(
            startingAt: expectedColumn,
            row: pending.row,
            in: state
        )

        return consumedErasedTail && cursor.column == expectedColumn
    }

    func highestExpectedColumnAfterErasedTail(
        startingAt column: Int,
        row: Int,
        in state: RemotePaneGridState
    ) -> Int {
        authoritativeErasedTailEndColumn(startingAt: column, row: row, in: state).column
    }

    func authoritativeErasedTailEndColumn(
        startingAt column: Int,
        row: Int,
        in state: RemotePaneGridState
    ) -> (column: Int, consumedTail: Bool) {
        var expectedColumn = column
        var consumedTail = false

        while let erased = erasedPending.first(where: {
            $0.prediction.row == row && $0.prediction.column == expectedColumn
        }) {
            guard authoritativeState(state, matches: erased.prediction) else {
                break
            }
            consumedTail = true
            expectedColumn = erased.prediction.column + erased.prediction.width
        }

        return (expectedColumn, consumedTail)
    }

    func authoritativeCursorLineChanged(
        from previousState: RemotePaneGridState?,
        to state: RemotePaneGridState
    ) -> Bool {
        guard let previousCursor = previousState?.cursor,
              let nextCursor = state.cursor else {
            return false
        }

        return previousCursor.row != nextCursor.row
    }

    func authoritativeCursorRowTextOrWidthChanged(
        from previousState: RemotePaneGridState?,
        to state: RemotePaneGridState,
        excluding ignoredColumnSpans: [Range<Int>] = []
    ) -> Bool {
        guard let previousCursor = previousState?.cursor,
              let nextCursor = state.cursor,
              previousCursor.row == nextCursor.row,
              let previousCells = rowCells(in: previousState, row: previousCursor.row),
              let nextCells = rowCells(in: state, row: nextCursor.row) else {
            return false
        }

        guard previousCells.count == nextCells.count else {
            return true
        }

        for column in previousCells.indices {
            if ignoredColumnSpans.contains(where: { $0.contains(column) }) {
                continue
            }
            if previousCells[column].text != nextCells[column].text ||
                previousCells[column].width != nextCells[column].width {
                return true
            }
        }
        return false
    }

    func predictionSpan(for pending: PendingPrediction) -> Range<Int> {
        pending.column..<(pending.column + pending.width)
    }

    func authoritativeCursor(
        in state: RemotePaneGridState,
        advancedPast pending: PendingPrediction
    ) -> Bool {
        guard let cursor = state.cursor else {
            return false
        }
        guard cursor.cursorVersion > pending.baselineCursor.cursorVersion else {
            return false
        }
        return cursor.row == pending.row &&
            cursor.column == pending.column + pending.width
    }

    func authoritativeCursorContradictsPendingInput(
        _ pending: PendingPrediction,
        in state: RemotePaneGridState
    ) -> Bool {
        guard let cursor = state.cursor,
              cursor.cursorVersion > pending.baselineCursor.cursorVersion else {
            return false
        }

        guard cursor.row == pending.row else {
            return true
        }

        let expectedColumn = pending.column + pending.width
        if cursor.column == expectedColumn {
            return false
        }

        let lowestExpectedColumn = min(pending.baselineCursor.column, pending.column)
        if cursor.column >= lowestExpectedColumn,
           cursor.column <= pending.column {
            return false
        }

        return true
    }

    func baselineCell(row: Int, column: Int) -> RemoteGridCell? {
        guard let currentState else {
            return nil
        }
        return cell(in: currentState, row: row, column: column)
    }

    func baselineStyle(row: Int, column: Int) -> RemoteCellStyle {
        guard let currentState,
              let cell = cell(in: currentState, row: row, column: column) else {
            return .normal
        }
        return cell.style
    }

    func cell(
        in state: RemotePaneGridState,
        row: Int,
        column: Int
    ) -> RemoteGridCell? {
        guard row >= 0,
              row < state.rows.count,
              column >= 0,
              column < state.rows[row].count else {
            return nil
        }
        return state.rows[row][column]
    }

    func rowCells(in state: RemotePaneGridState?, row: Int) -> [RemoteGridCell]? {
        guard let state,
              row >= 0,
              row < state.rows.count else {
            return nil
        }
        return state.rows[row]
    }

    func overlayCursor(after visible: [PendingPrediction]) -> RemoteCursorState? {
        guard let last = visible.last,
              let cursor = currentState?.cursor else {
            return nil
        }

        return RemoteCursorState(
            row: last.row,
            column: last.column + last.width,
            visible: cursor.visible,
            shape: cursor.shape,
            cursorVersion: cursor.cursorVersion
        )
    }

    func overlayCells(for pending: PendingPrediction) -> [RemotePaneOverlayCell] {
        var cells = [
            RemotePaneOverlayCell(row: pending.row, column: pending.column, cell: pending.cell)
        ]
        if pending.width == 2 {
            cells.append(RemotePaneOverlayCell(
                row: pending.row,
                column: pending.column + 1,
                cell: .continuation
            ))
        }
        return cells
    }

    mutating func clearPredictionState() {
        hiddenPending = nil
        visiblePending.removeAll()
        erasedPending.removeAll()
        echoConfidence = false
    }

    var hasPendingPredictions: Bool {
        hiddenPending != nil || !visiblePending.isEmpty || !erasedPending.isEmpty
    }

    mutating func suppressPredictionsUntilAuthoritativeState() {
        clearPredictionState()
        currentState = nil
        currentEpoch = nil
    }

    mutating func startCooldown(now: TimeInterval) {
        cooldownUntil = now + cooldownDuration
    }

    mutating func startFailClosedCooldown() {
        cooldownUntil = .infinity
    }

    static func tentativeCell(
        text: String,
        width: Int,
        baseStyle: RemoteCellStyle
    ) -> RemoteGridCell {
        var style = baseStyle
        style.faint = true
        style.underline = .single
        return RemoteGridCell.text(text, width: width, style: style)
    }
}

private extension RemotePredictionEpoch {
    var hardIdentity: RemotePredictiveEchoEngine.PredictionHardIdentity {
        RemotePredictiveEchoEngine.PredictionHardIdentity(
            workspaceID: workspaceID,
            paneID: paneID,
            paneGeneration: paneGeneration,
            keyframeID: keyframeID,
            gridSize: gridSize,
            activeScreen: activeScreen
        )
    }
}
