import XCTest
@testable import Fantastty

final class RemotePredictiveEchoEngineTests: XCTestCase {
    private let start: TimeInterval = 1_000

    func testFirstPrintableInputStaysHiddenUntilMatchingAuthoritativeEchoProvesConfidence() {
        var engine = makeEngine()
        engine.observeAuthoritativeState(makeState())

        XCTAssertEqual(engine.observeLocalInput(.directText("a"), now: start), .hiddenPendingEcho)
        XCTAssertFalse(engine.hasEchoConfidence)
        XCTAssertTrue(engine.visibleOverlay(now: start + 1).cells.isEmpty)
        XCTAssertEqual(engine.debugPendingTextForTests, "a")

        engine.observeAuthoritativeState(
            makeState(rowText: "a", cursorColumn: 1, cursorVersion: 2),
            now: start + 0.01
        )

        XCTAssertTrue(engine.hasEchoConfidence)
        XCTAssertTrue(engine.visibleOverlay(now: start + 1).cells.isEmpty)
        XCTAssertNil(engine.debugPendingTextForTests)
    }

    func testHiddenPendingInputCanGainEchoConfidenceAcrossCursorVersionProgress() {
        var engine = makeEngine()
        engine.observeAuthoritativeState(makeState())

        XCTAssertEqual(engine.observeLocalInput(.directText("a"), now: start), .hiddenPendingEcho)
        engine.observeAuthoritativeState(
            makeState(
                rowText: "a",
                cursorColumn: 1,
                cursorVersion: 2
            ),
            now: start + 0.01
        )

        XCTAssertTrue(engine.hasEchoConfidence)
        XCTAssertNil(engine.debugPendingTextForTests)
        XCTAssertTrue(engine.visibleOverlay(now: start + 1).cells.isEmpty)
    }

    func testHiddenPendingInputDoesNotGainEchoConfidenceFromRegressedCursorVersion() {
        var engine = makeEngine()
        engine.observeAuthoritativeState(makeState(cursorVersion: 3))

        XCTAssertEqual(engine.observeLocalInput(.directText("a"), now: start), .hiddenPendingEcho)
        engine.observeAuthoritativeState(
            makeState(
                rowText: "a",
                cursorColumn: 1,
                cursorVersion: 2
            ),
            now: start + 0.01
        )

        XCTAssertFalse(engine.hasEchoConfidence)
        XCTAssertEqual(engine.debugPendingTextForTests, "a")
        XCTAssertTrue(engine.visibleOverlay(now: start + 1).cells.isEmpty)
        XCTAssertEqual(engine.observeLocalInput(.directText("b"), now: start + 0.01), .forwardOnly)
    }

    func testHiddenPendingInputDoesNotGainEchoConfidenceFromTextMatchWithoutCursorProof() {
        var engine = makeEngine()
        engine.observeAuthoritativeState(makeState())

        XCTAssertEqual(engine.observeLocalInput(.directText("a"), now: start), .hiddenPendingEcho)
        engine.observeAuthoritativeState(
            makeState(rowText: "a", cursorColumn: 1),
            now: start + 0.01
        )

        XCTAssertFalse(engine.hasEchoConfidence)
        XCTAssertEqual(engine.debugPendingTextForTests, "a")
        XCTAssertTrue(engine.visibleOverlay(now: start + 1).cells.isEmpty)
    }

    func testHiddenPendingInputDoesNotGainEchoConfidenceFromUnchangedBaselineCell() {
        var engine = makeEngine()
        engine.observeAuthoritativeState(makeState(rowText: "a"))

        XCTAssertEqual(engine.observeLocalInput(.directText("a"), now: start), .hiddenPendingEcho)
        engine.observeAuthoritativeState(makeState(rowText: "a"), now: start + 0.01)

        XCTAssertFalse(engine.hasEchoConfidence)
        XCTAssertEqual(engine.debugPendingTextForTests, "a")
        XCTAssertEqual(engine.observeLocalInput(.directText("b"), now: start + 0.01), .forwardOnly)
        XCTAssertTrue(engine.visibleOverlay(now: start + 1).cells.isEmpty)
    }

    func testHiddenPendingInputDoesNotGainEchoConfidenceFromStyleOnlyBaselineChange() {
        var restyled = RemoteCellStyle.normal
        restyled.bold = true

        var engine = makeEngine()
        engine.observeAuthoritativeState(makeState(rowCells: [.text("a")]))

        XCTAssertEqual(engine.observeLocalInput(.directText("a"), now: start), .hiddenPendingEcho)
        engine.observeAuthoritativeState(
            makeState(rowCells: [.text("a", style: restyled)]),
            now: start + 0.01
        )

        XCTAssertFalse(engine.hasEchoConfidence)
        XCTAssertEqual(engine.debugPendingTextForTests, "a")
        XCTAssertFalse(engine.isCoolingDown(now: start + 0.1))
        XCTAssertTrue(engine.visibleOverlay(now: start + 1).cells.isEmpty)
    }

    func testHiddenPendingInputDoesNotGainEchoConfidenceFromSameGlyphCursorProgress() {
        var engine = makeEngine()
        engine.observeAuthoritativeState(makeState(rowCells: [.blank]))

        XCTAssertEqual(engine.observeLocalInput(.directText(" "), now: start), .hiddenPendingEcho)
        engine.observeAuthoritativeState(
            makeState(
                rowCells: [.blank],
                cursorColumn: 1,
                cursorVersion: 2
            ),
            now: start + 0.01
        )

        XCTAssertFalse(engine.hasEchoConfidence)
        XCTAssertEqual(engine.debugPendingTextForTests, " ")
        XCTAssertTrue(engine.visibleOverlay(now: start + 1).cells.isEmpty)
    }

    func testSecondPreConfidencePrintableInvalidatesHiddenProof() {
        var engine = makeEngine()
        engine.observeAuthoritativeState(makeState())

        XCTAssertEqual(engine.observeLocalInput(.directText("a"), now: start), .hiddenPendingEcho)
        XCTAssertEqual(engine.observeLocalInput(.directText("b"), now: start + 0.01), .forwardOnly)

        XCTAssertFalse(engine.hasEchoConfidence)
        XCTAssertTrue(engine.visibleOverlay(now: start + 1).cells.isEmpty)
        XCTAssertNil(engine.debugPendingTextForTests)

        engine.observeAuthoritativeState(
            makeState(rowText: "a", cursorColumn: 1, cursorVersion: 2),
            now: start + 0.02
        )

        XCTAssertFalse(engine.hasEchoConfidence)
        XCTAssertEqual(engine.observeLocalInput(.directText("c"), now: start + 0.03), .forwardOnly)
        XCTAssertNil(engine.debugPendingTextForTests)
    }

    func testEchoOffSecondCharacterIsNotRetainedBeforeConfidence() {
        var engine = makeEngine(noAckTimeout: 0.25)
        engine.observeAuthoritativeState(makeState())

        XCTAssertEqual(engine.observeLocalInput(.directText("s"), now: start), .hiddenPendingEcho)
        XCTAssertEqual(engine.observeLocalInput(.directText("e"), now: start + 0.01), .forwardOnly)
        XCTAssertEqual(engine.observeLocalInput(.directText("c"), now: start + 0.02), .forwardOnly)
        engine.expireTimers(now: start + 0.26)

        XCTAssertNil(engine.debugPendingTextForTests)
        XCTAssertTrue(engine.visibleOverlay(now: start + 0.30).cells.isEmpty)
    }

    func testSecondHiddenPrintableNearEdgeIsForwardOnlyBeforeGeometryRejection() {
        var engine = makeEngine()
        engine.observeAuthoritativeState(makeState(cursorColumn: 4))

        XCTAssertEqual(engine.observeLocalInput(.directText("a"), now: start), .hiddenPendingEcho)
        XCTAssertEqual(engine.observeLocalInput(.directText("界"), now: start + 0.01), .forwardOnly)

        XCTAssertFalse(engine.hasEchoConfidence)
        XCTAssertNil(engine.debugPendingTextForTests)
        XCTAssertTrue(engine.visibleOverlay(now: start + 1).cells.isEmpty)
    }

    func testNoAckTimeoutScrubsHiddenInputAndStartsCooldown() {
        var engine = makeEngine(noAckTimeout: 0.25, cooldownDuration: 1)
        engine.observeAuthoritativeState(makeState())

        XCTAssertEqual(engine.observeLocalInput(.directText("a"), now: start), .hiddenPendingEcho)
        engine.expireTimers(now: start + 0.26)

        XCTAssertFalse(engine.hasEchoConfidence)
        XCTAssertNil(engine.debugPendingTextForTests)
        XCTAssertTrue(engine.visibleOverlay(now: start + 0.26).cells.isEmpty)
        XCTAssertTrue(engine.isCoolingDown(now: start + 0.26))
        XCTAssertEqual(engine.observeLocalInput(.directText("b"), now: start + 0.27), .forwardOnly)
    }

    func testNoAckTimeoutScrubsErasedPendingAndAllowsReproofAfterCooldown() {
        var engine = makeEngine(noAckTimeout: 0.08, cooldownDuration: 0.1)
        engine.observeAuthoritativeState(makeState())
        XCTAssertEqual(engine.observeLocalInput(.directText("a"), now: start), .hiddenPendingEcho)
        engine.observeAuthoritativeState(
            makeState(rowText: "a", cursorColumn: 1, cursorVersion: 2),
            now: start + 0.01
        )
        XCTAssertTrue(engine.hasEchoConfidence)

        let inputTime = start + 0.1
        XCTAssertEqual(engine.observeLocalInput(.directText("b"), now: inputTime), .accepted)
        XCTAssertEqual(engine.observeLocalInput(.plainErase(), now: inputTime + 0.01), .accepted)

        engine.expireTimers(now: inputTime + 0.081)
        XCTAssertFalse(engine.hasEchoConfidence)
        XCTAssertTrue(engine.isCoolingDown(now: inputTime + 0.081))
        XCTAssertEqual(engine.observeLocalInput(.directText("c"), now: inputTime + 0.082), .forwardOnly)

        XCTAssertEqual(engine.observeLocalInput(.directText("c"), now: inputTime + 0.182), .hiddenPendingEcho)
        XCTAssertEqual(engine.debugPendingTextForTests, "c")
    }

    func testTimedLateAuthoritativeEchoCannotProveExpiredHiddenPendingInput() {
        var engine = makeEngine(noAckTimeout: 0.25, cooldownDuration: 1)
        engine.observeAuthoritativeState(makeState())

        XCTAssertEqual(engine.observeLocalInput(.directText("a"), now: start), .hiddenPendingEcho)

        let lateTime = start + 0.26
        engine.observeAuthoritativeState(
            makeState(rowText: "a", cursorColumn: 1, cursorVersion: 2),
            now: lateTime
        )

        XCTAssertFalse(engine.hasEchoConfidence)
        XCTAssertNil(engine.debugPendingTextForTests)
        XCTAssertTrue(engine.visibleOverlay(now: lateTime).cells.isEmpty)
        XCTAssertTrue(engine.isCoolingDown(now: lateTime))
    }

    func testUntimedAuthoritativeObservationCannotProvePendingInput() {
        var engine = makeEngine()
        engine.observeAuthoritativeState(makeState())

        XCTAssertEqual(engine.observeLocalInput(.directText("a"), now: start), .hiddenPendingEcho)
        engine.observeAuthoritativeState(makeState(rowText: "a", cursorColumn: 1, cursorVersion: 2))

        XCTAssertFalse(engine.hasEchoConfidence)
        XCTAssertNil(engine.debugPendingTextForTests)
        XCTAssertTrue(engine.visibleOverlay(now: start + 0.01).cells.isEmpty)
        XCTAssertTrue(engine.isCoolingDown(now: start + 0.01))
        XCTAssertEqual(engine.observeLocalInput(.directText("b"), now: start + 0.01), .forwardOnly)
    }

    func testUntimedAuthoritativeObservationCannotProveVisiblePendingInput() {
        var engine = makeEchoConfidentEngine()
        let inputTime = start + 0.1

        XCTAssertEqual(engine.observeLocalInput(.directText("b"), now: inputTime), .accepted)
        engine.observeAuthoritativeState(makeState(rowText: "ab", cursorColumn: 2, cursorVersion: 3))

        XCTAssertFalse(engine.hasEchoConfidence)
        XCTAssertTrue(engine.visibleOverlay(now: inputTime + 0.051).cells.isEmpty)
        XCTAssertTrue(engine.isCoolingDown(now: inputTime + 0.052))
        XCTAssertEqual(engine.observeLocalInput(.directText("c"), now: inputTime + 0.052), .forwardOnly)
    }

    func testUntimedHardIdentityChangeWithHiddenPendingStartsFreshEpoch() {
        var engine = makeEngine()
        engine.observeAuthoritativeState(makeState())

        XCTAssertEqual(engine.observeLocalInput(.directText("a"), now: start), .hiddenPendingEcho)
        engine.observeAuthoritativeState(makeState(
            rowText: "a",
            keyframeID: 12,
            cursorColumn: 1,
            cursorVersion: 2
        ))

        XCTAssertFalse(engine.hasEchoConfidence)
        XCTAssertNil(engine.debugPendingTextForTests)
        XCTAssertTrue(engine.visibleOverlay(now: start + 0.01).cells.isEmpty)
        XCTAssertFalse(engine.isCoolingDown(now: start + 0.01))
        XCTAssertEqual(engine.observeLocalInput(.directText("b"), now: start + 0.01), .hiddenPendingEcho)
        XCTAssertEqual(engine.debugPendingTextForTests, "b")
    }

    func testUntimedHardIdentityChangeWithVisiblePendingStartsFreshEpoch() {
        var engine = makeEchoConfidentEngine()
        let inputTime = start + 0.1

        XCTAssertEqual(engine.observeLocalInput(.directText("b"), now: inputTime), .accepted)
        engine.observeAuthoritativeState(makeState(
            rowText: "ab",
            keyframeID: 12,
            cursorColumn: 2,
            cursorVersion: 3
        ))

        XCTAssertFalse(engine.hasEchoConfidence)
        XCTAssertTrue(engine.visibleOverlay(now: inputTime + 0.051).cells.isEmpty)
        XCTAssertFalse(engine.isCoolingDown(now: inputTime + 0.052))
        XCTAssertEqual(engine.observeLocalInput(.directText("c"), now: inputTime + 0.052), .hiddenPendingEcho)
        XCTAssertEqual(engine.debugPendingTextForTests, "c")
    }

    func testTimedAuthoritativeObservationCanProveImmediatePendingInput() {
        var engine = makeEngine()
        engine.observeAuthoritativeState(makeState())

        XCTAssertEqual(engine.observeLocalInput(.directText("a"), now: start), .hiddenPendingEcho)
        engine.observeAuthoritativeState(
            makeState(rowText: "a", cursorColumn: 1, cursorVersion: 2),
            now: start + 0.01
        )

        XCTAssertTrue(engine.hasEchoConfidence)
        XCTAssertNil(engine.debugPendingTextForTests)
        XCTAssertTrue(engine.visibleOverlay(now: start + 0.01).cells.isEmpty)
    }

    func testLatencyGateShowsOnlyEchoConfidentPredictionsAfterThreshold() {
        var engine = makeEchoConfidentEngine()
        let inputTime = start + 0.1

        XCTAssertEqual(engine.observeLocalInput(.directText("b"), now: inputTime), .accepted)
        XCTAssertTrue(engine.visibleOverlay(now: inputTime + 0.049).cells.isEmpty)

        let overlay = engine.visibleOverlay(now: inputTime + 0.051)
        XCTAssertEqual(overlay.cells.count, 1)
        XCTAssertEqual(overlay.cells.first?.row, 0)
        XCTAssertEqual(overlay.cells.first?.column, 1)
        XCTAssertEqual(overlay.cells.first?.cell.text, "b")
        XCTAssertEqual(overlay.cursor?.column, 2)
    }

    func testVisibleOverlayDoesNotRenderSuffixAfterPendingPrefixExpiresWithoutTimerSweep() {
        var engine = makeEngine(latencyThreshold: 0.05, noAckTimeout: 0.08)
        engine.observeAuthoritativeState(makeState())
        XCTAssertEqual(engine.observeLocalInput(.directText("a"), now: start), .hiddenPendingEcho)
        engine.observeAuthoritativeState(
            makeState(rowText: "a", cursorColumn: 1, cursorVersion: 2),
            now: start + 0.01
        )
        XCTAssertTrue(engine.hasEchoConfidence)

        let inputTime = start + 0.1
        XCTAssertEqual(engine.observeLocalInput(.directText("b"), now: inputTime), .accepted)
        XCTAssertEqual(engine.observeLocalInput(.directText("c"), now: inputTime + 0.04), .accepted)

        XCTAssertEqual(
            engine.visibleOverlay(now: inputTime + 0.051).cells.map { $0.cell.text },
            ["b"]
        )
        XCTAssertTrue(engine.visibleOverlay(now: inputTime + 0.1).cells.isEmpty)
    }

    func testVisibleOverlayDoesNotRenderExpiredPendingPredictionWithoutTimerSweep() {
        var engine = makeEngine(latencyThreshold: 0.05, noAckTimeout: 0.08)
        engine.observeAuthoritativeState(makeState())
        XCTAssertEqual(engine.observeLocalInput(.directText("a"), now: start), .hiddenPendingEcho)
        engine.observeAuthoritativeState(
            makeState(rowText: "a", cursorColumn: 1, cursorVersion: 2),
            now: start + 0.01
        )
        XCTAssertTrue(engine.hasEchoConfidence)

        let inputTime = start + 0.1
        XCTAssertEqual(engine.observeLocalInput(.directText("b"), now: inputTime), .accepted)
        XCTAssertEqual(engine.visibleOverlay(now: inputTime + 0.051).cells.map { $0.cell.text }, ["b"])
        XCTAssertTrue(engine.visibleOverlay(now: inputTime + 0.081).cells.isEmpty)
    }

    func testIdleCursorProgressDoesNotClearEchoConfidence() {
        var engine = makeEchoConfidentEngine()
        engine.observeAuthoritativeState(makeState(
            rowText: "a",
            cursorColumn: 2,
            cursorVersion: 3
        ))
        let inputTime = start + 0.1

        XCTAssertEqual(engine.observeLocalInput(.directText("x"), now: inputTime), .accepted)

        let overlay = engine.visibleOverlay(now: inputTime + 0.051)
        XCTAssertEqual(overlay.cells.map { $0.cell.text }, ["x"])
        XCTAssertEqual(overlay.cells.first?.column, 2)
        XCTAssertTrue(engine.hasEchoConfidence)
    }

    func testVisibleSameGlyphSpaceOverBlankAcknowledgesWithCursorProof() {
        var engine = makeEchoConfidentEngine()
        let inputTime = start + 0.1

        XCTAssertEqual(engine.observeLocalInput(.directText(" "), now: inputTime), .accepted)
        XCTAssertEqual(engine.visibleOverlay(now: inputTime + 0.051).cells.map { $0.cell.text }, [" "])

        engine.observeAuthoritativeState(
            makeState(
                rowCells: [.text("a"), .blank],
                cursorColumn: 2,
                cursorVersion: 3
            ),
            now: inputTime + 0.08
        )
        engine.expireTimers(now: inputTime + 0.7)

        XCTAssertTrue(engine.hasEchoConfidence)
        XCTAssertFalse(engine.isCoolingDown(now: inputTime + 0.7))
        XCTAssertTrue(engine.visibleOverlay(now: inputTime + 0.7).cells.isEmpty)
        XCTAssertEqual(engine.observeLocalInput(.directText("x"), now: inputTime + 0.71), .accepted)
    }

    func testCoalescedVisibleAcknowledgementConsumesSameGlyphSpaceBeforeChangedGlyph() {
        var engine = makeEchoConfidentEngine()
        let inputTime = start + 0.1

        XCTAssertEqual(engine.observeLocalInput(.directText(" "), now: inputTime), .accepted)
        XCTAssertEqual(engine.observeLocalInput(.directText("x"), now: inputTime + 0.01), .accepted)

        engine.observeAuthoritativeState(
            makeState(
                rowCells: [.text("a"), .blank, .text("x")],
                cursorColumn: 3,
                cursorVersion: 3
            ),
            now: inputTime + 0.08
        )

        XCTAssertTrue(engine.hasEchoConfidence)
        XCTAssertFalse(engine.isCoolingDown(now: inputTime + 0.08))
        XCTAssertTrue(engine.visibleOverlay(now: inputTime + 0.08).cells.isEmpty)

        XCTAssertEqual(engine.observeLocalInput(.directText("d"), now: inputTime + 0.09), .accepted)
        let overlay = engine.visibleOverlay(now: inputTime + 0.141)
        XCTAssertEqual(overlay.cells.map { $0.cell.text }, ["d"])
        XCTAssertEqual(overlay.cells.first?.column, 3)
    }

    func testSameRowAuthoritativeChangeOutsideVisiblePredictionClearsOverlayAndStartsCooldown() {
        var engine = makeEchoConfidentEngine()
        let inputTime = start + 0.1

        XCTAssertEqual(engine.observeLocalInput(.directText("b"), now: inputTime), .accepted)

        let mismatchTime = inputTime + 0.08
        engine.observeAuthoritativeState(
            makeState(
                rowCells: [.text("a"), .blank, .text("z")],
                cursorColumn: 1,
                cursorVersion: 3
            ),
            now: mismatchTime
        )

        XCTAssertFalse(engine.hasEchoConfidence)
        XCTAssertTrue(engine.visibleOverlay(now: mismatchTime + 0.01).cells.isEmpty)
        XCTAssertTrue(engine.isCoolingDown(now: mismatchTime + 0.01))
    }

    func testSameRowAuthoritativeContentChangeWithoutPendingClearsEchoConfidence() {
        var engine = makeEchoConfidentEngine()

        engine.observeAuthoritativeState(makeState(
            rowText: "pass",
            cursorColumn: 0,
            cursorVersion: 3
        ))
        let inputTime = start + 0.1

        XCTAssertFalse(engine.hasEchoConfidence)
        XCTAssertEqual(engine.observeLocalInput(.directText("s"), now: inputTime), .hiddenPendingEcho)
        XCTAssertEqual(engine.debugPendingTextForTests, "s")
        XCTAssertTrue(engine.visibleOverlay(now: inputTime + 0.051).cells.isEmpty)
    }

    func testIdleCursorLineJumpRequiresNextPrintableToReproveEchoConfidence() {
        var engine = makeEchoConfidentEngine()
        engine.observeAuthoritativeState(makeState(
            rowText: "a",
            cursorRow: 1,
            cursorColumn: 0,
            cursorVersion: 3
        ))
        let inputTime = start + 0.1

        XCTAssertEqual(engine.observeLocalInput(.directText("x"), now: inputTime), .hiddenPendingEcho)
        XCTAssertEqual(engine.debugPendingTextForTests, "x")
        XCTAssertTrue(engine.visibleOverlay(now: inputTime + 0.051).cells.isEmpty)
        XCTAssertFalse(engine.hasEchoConfidence)
    }

    func testPredictionAtLastColumnIsNotAcceptedWithoutWrapProof() {
        var engine = makeEchoConfidentEngine()
        let inputTime = start + 0.1
        engine.observeAuthoritativeState(makeState(rowText: "a", cursorColumn: 5, cursorVersion: 3))

        let result = engine.observeLocalInput(.directText("z"), now: inputTime)
        XCTAssertTrue(result == .rejected || result == .forwardOnly)

        let overlay = engine.visibleOverlay(now: inputTime + 0.051)
        XCTAssertTrue(overlay.cells.isEmpty)
        XCTAssertNil(overlay.cursor)
    }

    func testTentativeOverlayPreservesUnderlyingCellStyle() {
        var style = RemoteCellStyle.normal
        style.foreground = .indexed(2)
        style.bold = true

        var engine = makeEchoConfidentEngine()
        let inputTime = start + 0.1
        engine.observeAuthoritativeState(makeState(
            rowCells: [.text("a"), .text(" ", style: style)],
            cursorColumn: 1,
            cursorVersion: 3
        ))

        XCTAssertEqual(engine.observeLocalInput(.directText("x"), now: inputTime), .accepted)

        let cell = engine.visibleOverlay(now: inputTime + 0.051).cells.first?.cell
        XCTAssertEqual(cell?.text, "x")
        XCTAssertEqual(cell?.style.foreground, .indexed(2))
        XCTAssertEqual(cell?.style.bold, true)
        XCTAssertEqual(cell?.style.faint, true)
        XCTAssertEqual(cell?.style.underline, .dotted)
        XCTAssertEqual(cell?.style.blink, true)
    }

    func testAuthoritativeMismatchClearsOverlayAndStartsCooldownWithoutKeyframeRequest() {
        var engine = makeEngine(cooldownDuration: 60)
        engine.observeAuthoritativeState(makeState())

        XCTAssertEqual(engine.observeLocalInput(.directText("x"), now: start), .hiddenPendingEcho)
        engine.observeAuthoritativeState(makeState(rowText: "z", cursorColumn: 1))

        XCTAssertFalse(engine.hasEchoConfidence)
        XCTAssertNil(engine.debugPendingTextForTests)
        XCTAssertTrue(engine.visibleOverlay(now: start).cells.isEmpty)
        XCTAssertTrue(engine.isCoolingDown(now: start))
        XCTAssertFalse(engine.needsKeyframeRequest)
    }

    func testUntimedAuthoritativeMismatchFailsClosedAgainstStaleInputTime() {
        var engine = makeEngine(cooldownDuration: 1)
        engine.observeAuthoritativeState(makeState())

        XCTAssertEqual(engine.observeLocalInput(.directText("x"), now: start), .hiddenPendingEcho)
        engine.observeAuthoritativeState(makeState(rowText: "z", cursorColumn: 1))

        let delayedInputTime = start + 10.1
        XCTAssertTrue(engine.isCoolingDown(now: delayedInputTime))
        XCTAssertEqual(engine.observeLocalInput(.directText("y"), now: delayedInputTime), .forwardOnly)
    }

    func testUntimedHardIdentityChangeClearsPreviousFailClosedCooldown() {
        var engine = makeEngine(cooldownDuration: 1)
        engine.observeAuthoritativeState(makeState())

        XCTAssertEqual(engine.observeLocalInput(.directText("x"), now: start), .hiddenPendingEcho)
        engine.observeAuthoritativeState(makeState(rowText: "z", cursorColumn: 1))
        XCTAssertTrue(engine.isCoolingDown(now: start + 10.1))

        engine.observeAuthoritativeState(makeState(
            rowText: "z",
            keyframeID: 12,
            cursorColumn: 1,
            cursorVersion: 2
        ))

        XCTAssertFalse(engine.isCoolingDown(now: start + 10.2))
        XCTAssertEqual(engine.observeLocalInput(.directText("y"), now: start + 10.2), .hiddenPendingEcho)
        XCTAssertEqual(engine.debugPendingTextForTests, "y")
    }

    func testMismatchCooldownStartsAtAuthoritativeObservationTime() {
        var engine = makeEngine(cooldownDuration: 1)
        engine.observeAuthoritativeState(makeState())

        XCTAssertEqual(engine.observeLocalInput(.directText("x"), now: start), .hiddenPendingEcho)

        let mismatchTime = start + 10
        engine.observeAuthoritativeState(makeState(rowText: "z", cursorColumn: 1), now: mismatchTime)

        XCTAssertTrue(engine.isCoolingDown(now: mismatchTime + 0.1))
        XCTAssertEqual(engine.observeLocalInput(.directText("y"), now: mismatchTime + 0.1), .forwardOnly)
        XCTAssertFalse(engine.isCoolingDown(now: mismatchTime + 1.1))
        XCTAssertEqual(engine.observeLocalInput(.directText("y"), now: mismatchTime + 1.1), .hiddenPendingEcho)
        XCTAssertEqual(engine.debugPendingTextForTests, "y")
    }

    func testHiddenPendingInputDoesNotGainEchoConfidenceAcrossEpochChange() {
        var engine = makeEngine()
        engine.observeAuthoritativeState(makeState())

        XCTAssertEqual(engine.observeLocalInput(.directText("a"), now: start), .hiddenPendingEcho)
        engine.observeAuthoritativeState(
            makeState(
                rowText: "a",
                keyframeID: 12,
                cursorColumn: 1,
                cursorVersion: 2
            ),
            now: start + 0.01
        )

        XCTAssertFalse(engine.hasEchoConfidence)
        XCTAssertNil(engine.debugPendingTextForTests)
        XCTAssertTrue(engine.visibleOverlay(now: start + 1).cells.isEmpty)
        XCTAssertEqual(engine.observeLocalInput(.directText("b"), now: start + 0.01), .hiddenPendingEcho)
    }

    func testEchoConfidenceDoesNotCarryAcrossEpochChangeWithoutPendingPredictions() {
        var engine = makeEchoConfidentEngine()

        engine.observeAuthoritativeState(makeState(
            rowText: "a",
            keyframeID: 12,
            cursorColumn: 1,
            cursorVersion: 3
        ))

        XCTAssertFalse(engine.hasEchoConfidence)
        XCTAssertEqual(engine.observeLocalInput(.directText("b"), now: start + 0.1), .hiddenPendingEcho)
        XCTAssertTrue(engine.visibleOverlay(now: start + 1).cells.isEmpty)
    }

    func testBarrierClearInvalidatesStateUntilFreshAuthoritativeStateArrives() {
        var engine = makeEngine()
        engine.observeAuthoritativeState(makeState())

        engine.clear(reason: .focusLost)

        XCTAssertEqual(engine.observeLocalInput(.directText("a"), now: start), .forwardOnly)
        XCTAssertNil(engine.debugPendingTextForTests)

        engine.observeAuthoritativeState(makeState())

        XCTAssertEqual(engine.observeLocalInput(.directText("a"), now: start + 0.01), .hiddenPendingEcho)
        XCTAssertEqual(engine.debugPendingTextForTests, "a")
    }

    func testBarrierClearClearsFailClosedCooldownForFreshAuthoritativeState() {
        var engine = makeEngine(cooldownDuration: 1)
        engine.observeAuthoritativeState(makeState())

        XCTAssertEqual(engine.observeLocalInput(.directText("x"), now: start), .hiddenPendingEcho)
        engine.observeAuthoritativeState(makeState(rowText: "z", cursorColumn: 1))
        XCTAssertTrue(engine.isCoolingDown(now: start + 10.1))

        engine.clear(reason: .focusLost)
        engine.observeAuthoritativeState(makeState())

        XCTAssertFalse(engine.isCoolingDown(now: start + 10.2))
        XCTAssertEqual(engine.observeLocalInput(.directText("y"), now: start + 10.2), .hiddenPendingEcho)
        XCTAssertEqual(engine.debugPendingTextForTests, "y")
    }

    func testUnsafeProvenanceIsForwardOnlyAndNeverPredicted() {
        let unsafeInputs: [RemotePaneInput] = [
            .paste("a"),
            .imeCommit("a"),
            .escapeSequence(),
            RemotePaneInput(data: Data([0]), source: .mouse),
            RemotePaneInput(data: Data([0]), source: .localBinding)
        ]

        for input in unsafeInputs {
            var engine = makeEngine()
            engine.observeAuthoritativeState(makeState())

            XCTAssertEqual(engine.observeLocalInput(input, now: start), .forwardOnly)
            XCTAssertFalse(engine.hasEchoConfidence)
            XCTAssertNil(engine.debugPendingTextForTests)
            XCTAssertTrue(engine.visibleOverlay(now: start + 1).cells.isEmpty)
        }
    }

    func testDirectInputSourceClassifiesPlainEraseBytes() {
        XCTAssertEqual(RemotePaneInputSource.directInputSource(for: Data([0x7F])), .plainEraseByte)
        XCTAssertEqual(RemotePaneInputSource.directInputSource(for: Data([0x08])), .plainEraseByte)
        XCTAssertEqual(RemotePaneInputSource.directInputSource(for: Data("a".utf8)), .directKey)
        XCTAssertEqual(RemotePaneInputSource.directInputSource(for: Data("\n".utf8)), .directKey)
    }

    func testProvenanceIneligibleInputClearsVisiblePredictionBeforeItCanRender() {
        let unsafeInputs: [RemotePaneInput] = [
            .paste("a"),
            .imeCommit("a"),
            .escapeSequence(),
            RemotePaneInput(data: Data([0]), source: .mouse),
            RemotePaneInput(data: Data([0]), source: .localBinding)
        ]

        for input in unsafeInputs {
            var engine = makeEchoConfidentEngine()
            let inputTime = start + 0.1

            XCTAssertEqual(engine.observeLocalInput(.directText("b"), now: inputTime), .accepted)
            XCTAssertEqual(engine.observeLocalInput(input, now: inputTime + 0.001), .forwardOnly)

            XCTAssertFalse(engine.hasEchoConfidence)
            XCTAssertTrue(engine.visibleOverlay(now: inputTime + 0.051).cells.isEmpty)
            XCTAssertEqual(engine.observeLocalInput(.directText("c"), now: inputTime + 0.052), .forwardOnly)
            XCTAssertNil(engine.debugPendingTextForTests)

            engine.observeAuthoritativeState(makeState(cursorVersion: 3))

            XCTAssertEqual(engine.observeLocalInput(.directText("d"), now: inputTime + 0.053), .hiddenPendingEcho)
            XCTAssertEqual(engine.debugPendingTextForTests, "d")
        }
    }

    func testNonPrintableDirectInputClearsVisiblePredictionBeforeItCanRender() {
        let unsafeInputs: [RemotePaneInput] = [
            .directBytes([0x03])
        ]

        for input in unsafeInputs {
            var engine = makeEchoConfidentEngine()
            let inputTime = start + 0.1

            XCTAssertEqual(engine.observeLocalInput(.directText("b"), now: inputTime), .accepted)
            XCTAssertEqual(engine.observeLocalInput(input, now: inputTime + 0.001), .rejected)

            XCTAssertFalse(engine.hasEchoConfidence)
            XCTAssertTrue(engine.visibleOverlay(now: inputTime + 0.051).cells.isEmpty)
            XCTAssertEqual(engine.observeLocalInput(.directText("c"), now: inputTime + 0.052), .forwardOnly)
            XCTAssertNil(engine.debugPendingTextForTests)

            engine.observeAuthoritativeState(makeState(cursorVersion: 3))

            XCTAssertEqual(engine.observeLocalInput(.directText("d"), now: inputTime + 0.053), .hiddenPendingEcho)
            XCTAssertEqual(engine.debugPendingTextForTests, "d")
        }
    }

    func testNewlineOrCarriageReturnSuppressesPredictionUntilAuthoritativeStateAfterConfidence() {
        let lineBoundaryInputs: [RemotePaneInput] = [
            .directBytes([0x0A]),
            .directBytes([0x0D])
        ]

        for input in lineBoundaryInputs {
            var engine = makeEchoConfidentEngine()
            let inputTime = start + 0.1

            XCTAssertEqual(engine.observeLocalInput(input, now: inputTime), .rejected)
            XCTAssertFalse(engine.hasEchoConfidence)
            XCTAssertNil(engine.debugPendingTextForTests)

            XCTAssertEqual(engine.observeLocalInput(.directText("s"), now: inputTime + 0.001), .forwardOnly)
            XCTAssertNil(engine.debugPendingTextForTests)
            XCTAssertTrue(engine.visibleOverlay(now: inputTime + 0.052).cells.isEmpty)

            engine.observeAuthoritativeState(makeState(cursorVersion: 3))

            XCTAssertEqual(engine.observeLocalInput(.directText("t"), now: inputTime + 0.053), .hiddenPendingEcho)
            XCTAssertEqual(engine.debugPendingTextForTests, "t")
        }
    }

    func testProvenanceIneligibleInputScrubsHiddenPendingBeforeConfidence() {
        let unsafeInputs: [RemotePaneInput] = [
            .paste("a"),
            .imeCommit("a"),
            .escapeSequence(),
            RemotePaneInput(data: Data([0]), source: .mouse),
            RemotePaneInput(data: Data([0]), source: .localBinding)
        ]

        for input in unsafeInputs {
            var engine = makeEngine()
            engine.observeAuthoritativeState(makeState())

            XCTAssertEqual(engine.observeLocalInput(.directText("s"), now: start), .hiddenPendingEcho)
            XCTAssertEqual(engine.observeLocalInput(input, now: start + 0.001), .forwardOnly)

            XCTAssertFalse(engine.hasEchoConfidence)
            XCTAssertNil(engine.debugPendingTextForTests)
            XCTAssertTrue(engine.visibleOverlay(now: start + 0.051).cells.isEmpty)
            XCTAssertEqual(engine.observeLocalInput(.directText("t"), now: start + 0.052), .forwardOnly)
            XCTAssertNil(engine.debugPendingTextForTests)

            engine.observeAuthoritativeState(makeState(cursorVersion: 2))

            XCTAssertEqual(engine.observeLocalInput(.directText("u"), now: start + 0.053), .hiddenPendingEcho)
            XCTAssertEqual(engine.debugPendingTextForTests, "u")
        }
    }

    func testNonPrintableDirectInputScrubsHiddenPendingBeforeConfidence() {
        let unsafeInputs: [(input: RemotePaneInput, result: RemotePredictionInputResult)] = [
            (.directBytes([0x03]), .rejected)
        ]

        for (input, result) in unsafeInputs {
            var engine = makeEngine()
            engine.observeAuthoritativeState(makeState())

            XCTAssertEqual(engine.observeLocalInput(.directText("s"), now: start), .hiddenPendingEcho)
            XCTAssertEqual(engine.observeLocalInput(input, now: start + 0.001), result)

            XCTAssertFalse(engine.hasEchoConfidence)
            XCTAssertNil(engine.debugPendingTextForTests)
            XCTAssertTrue(engine.visibleOverlay(now: start + 0.051).cells.isEmpty)
            XCTAssertEqual(engine.observeLocalInput(.directText("t"), now: start + 0.052), .forwardOnly)
            XCTAssertNil(engine.debugPendingTextForTests)

            engine.observeAuthoritativeState(makeState(cursorVersion: 2))

            XCTAssertEqual(engine.observeLocalInput(.directText("u"), now: start + 0.053), .hiddenPendingEcho)
            XCTAssertEqual(engine.debugPendingTextForTests, "u")
        }
    }

    func testNewlineOrCarriageReturnScrubsHiddenPendingAndSuppressesPredictionUntilAuthoritativeState() {
        let lineBoundaryInputs: [RemotePaneInput] = [
            .directBytes([0x0A]),
            .directBytes([0x0D])
        ]

        for input in lineBoundaryInputs {
            var engine = makeEngine()
            engine.observeAuthoritativeState(makeState())

            XCTAssertEqual(engine.observeLocalInput(.directText("s"), now: start), .hiddenPendingEcho)
            XCTAssertEqual(engine.observeLocalInput(input, now: start + 0.001), .rejected)
            XCTAssertFalse(engine.hasEchoConfidence)
            XCTAssertNil(engine.debugPendingTextForTests)

            XCTAssertEqual(engine.observeLocalInput(.directText("t"), now: start + 0.002), .forwardOnly)
            XCTAssertNil(engine.debugPendingTextForTests)
            XCTAssertTrue(engine.visibleOverlay(now: start + 0.052).cells.isEmpty)

            engine.observeAuthoritativeState(makeState(cursorVersion: 2))

            XCTAssertEqual(engine.observeLocalInput(.directText("u"), now: start + 0.053), .hiddenPendingEcho)
            XCTAssertEqual(engine.debugPendingTextForTests, "u")
        }
    }

    func testPredictionRequiresPrimaryScreenAndVisibleCursor() {
        var alternateScreenEngine = makeEngine()
        alternateScreenEngine.observeAuthoritativeState(makeState(activeScreen: .alternate))

        XCTAssertEqual(alternateScreenEngine.observeLocalInput(.directText("a"), now: start), .forwardOnly)
        XCTAssertFalse(alternateScreenEngine.hasEchoConfidence)
        XCTAssertNil(alternateScreenEngine.debugPendingTextForTests)

        var hiddenCursorEngine = makeEngine()
        hiddenCursorEngine.observeAuthoritativeState(makeState(cursorVisible: false))

        XCTAssertEqual(hiddenCursorEngine.observeLocalInput(.directText("a"), now: start), .forwardOnly)
        XCTAssertFalse(hiddenCursorEngine.hasEchoConfidence)
        XCTAssertNil(hiddenCursorEngine.debugPendingTextForTests)
    }

    func testUnsafeAuthoritativeStateClearsFailClosedCooldownForFreshPrimaryState() {
        var engine = makeEngine(cooldownDuration: 1)
        engine.observeAuthoritativeState(makeState())

        XCTAssertEqual(engine.observeLocalInput(.directText("x"), now: start), .hiddenPendingEcho)
        engine.observeAuthoritativeState(makeState(rowText: "z", cursorColumn: 1))
        XCTAssertTrue(engine.isCoolingDown(now: start + 10.1))

        engine.observeAuthoritativeState(makeState(activeScreen: .alternate))
        engine.observeAuthoritativeState(makeState())

        XCTAssertFalse(engine.isCoolingDown(now: start + 10.2))
        XCTAssertEqual(engine.observeLocalInput(.directText("y"), now: start + 10.2), .hiddenPendingEcho)
        XCTAssertEqual(engine.debugPendingTextForTests, "y")
    }

    func testBackspaceBeforeHiddenEchoInvalidatesHiddenProofWithoutRevealingPrediction() {
        var engine = makeEngine()
        engine.observeAuthoritativeState(makeState())

        XCTAssertEqual(engine.observeLocalInput(.directText("h"), now: start), .hiddenPendingEcho)
        XCTAssertEqual(engine.observeLocalInput(.plainErase(), now: start + 0.01), .forwardOnly)

        XCTAssertNil(engine.debugPendingTextForTests)
        XCTAssertFalse(engine.hasEchoConfidence)
        XCTAssertTrue(engine.visibleOverlay(now: start + 1).cells.isEmpty)

        engine.observeAuthoritativeState(
            makeState(rowText: "h", cursorColumn: 1, cursorVersion: 2),
            now: start + 0.02
        )

        XCTAssertFalse(engine.hasEchoConfidence)
        XCTAssertNil(engine.debugPendingTextForTests)

        let inputTime = start + 0.03
        XCTAssertEqual(engine.observeLocalInput(.directText("x"), now: inputTime), .hiddenPendingEcho)
        XCTAssertEqual(engine.debugPendingTextForTests, "x")
        XCTAssertTrue(engine.visibleOverlay(now: inputTime + 0.051).cells.isEmpty)
    }

    func testBackspaceRemovesMostRecentDisplayedTentativeGrapheme() {
        var engine = makeEchoConfidentEngine()
        let inputTime = start + 0.1
        XCTAssertEqual(engine.observeLocalInput(.directText("b"), now: inputTime), .accepted)
        XCTAssertEqual(engine.observeLocalInput(.directText("c"), now: inputTime + 0.01), .accepted)
        XCTAssertEqual(
            engine.visibleOverlay(now: inputTime + 0.08).cells.map { $0.cell.text },
            ["b", "c"]
        )

        XCTAssertEqual(engine.observeLocalInput(.plainErase(), now: inputTime + 0.09), .accepted)
        XCTAssertEqual(
            engine.visibleOverlay(now: inputTime + 0.1).cells.map { $0.cell.text },
            ["b"]
        )

        XCTAssertEqual(engine.observeLocalInput(.directText("d"), now: inputTime + 0.101), .forwardOnly)
    }

    func testBackspaceBeforeLatencyThresholdKeepsEraseBarrierUntilAuthoritativeCatchUp() {
        var engine = makeEchoConfidentEngine()
        let inputTime = start + 0.1

        XCTAssertEqual(engine.observeLocalInput(.directText("b"), now: inputTime), .accepted)
        XCTAssertTrue(engine.visibleOverlay(now: inputTime + 0.001).cells.isEmpty)

        XCTAssertEqual(engine.observeLocalInput(.plainErase(), now: inputTime + 0.001), .accepted)
        XCTAssertTrue(engine.hasEchoConfidence)
        XCTAssertTrue(engine.visibleOverlay(now: inputTime + 0.051).cells.isEmpty)

        engine.observeAuthoritativeState(
            makeState(rowText: "ab", cursorColumn: 2, cursorVersion: 3),
            now: inputTime + 0.06
        )

        engine.observeAuthoritativeState(
            makeState(rowText: "a", cursorColumn: 1, cursorVersion: 4),
            now: inputTime + 0.07
        )
        XCTAssertEqual(engine.observeLocalInput(.directText("c"), now: inputTime + 0.071), .accepted)
        let overlay = engine.visibleOverlay(now: inputTime + 0.122)
        XCTAssertEqual(overlay.cells.map { $0.cell.text }, ["c"])
        XCTAssertEqual(overlay.cells.map { $0.column }, [1])
    }

    func testBackspaceRemovesUndisplayedLatestPredictionWithoutPurgingDisplayedPrefix() {
        var engine = makeEchoConfidentEngine()
        let inputTime = start + 0.1

        XCTAssertEqual(engine.observeLocalInput(.directText("b"), now: inputTime), .accepted)
        XCTAssertEqual(engine.observeLocalInput(.directText("c"), now: inputTime + 0.04), .accepted)
        XCTAssertEqual(engine.visibleOverlay(now: inputTime + 0.051).cells.map { $0.cell.text }, ["b"])

        XCTAssertEqual(engine.observeLocalInput(.plainErase(), now: inputTime + 0.052), .accepted)
        XCTAssertEqual(engine.visibleOverlay(now: inputTime + 0.053).cells.map { $0.cell.text }, ["b"])

        engine.observeAuthoritativeState(
            makeState(rowText: "abc", cursorColumn: 3, cursorVersion: 3),
            now: inputTime + 0.06
        )

        XCTAssertTrue(engine.hasEchoConfidence)
        XCTAssertFalse(engine.isCoolingDown(now: inputTime + 0.061))
        XCTAssertTrue(engine.visibleOverlay(now: inputTime + 0.061).cells.isEmpty)

        engine.observeAuthoritativeState(
            makeState(rowText: "ab", cursorColumn: 2, cursorVersion: 4),
            now: inputTime + 0.07
        )

        XCTAssertEqual(engine.observeLocalInput(.directText("d"), now: inputTime + 0.071), .accepted)
        let overlay = engine.visibleOverlay(now: inputTime + 0.122)
        XCTAssertEqual(overlay.cells.map { $0.cell.text }, ["d"])
        XCTAssertEqual(overlay.cells.map { $0.column }, [2])
    }

    func testPrintableDuringErasedBarrierRequiresFreshAuthoritativeReproof() {
        var engine = makeEchoConfidentEngine()
        let inputTime = start + 0.1

        XCTAssertEqual(engine.observeLocalInput(.directText("b"), now: inputTime), .accepted)
        XCTAssertEqual(engine.observeLocalInput(.plainErase(), now: inputTime + 0.01), .accepted)
        XCTAssertEqual(engine.observeLocalInput(.directText("c"), now: inputTime + 0.02), .forwardOnly)

        XCTAssertFalse(engine.hasEchoConfidence)
        XCTAssertNil(engine.debugPendingTextForTests)
        XCTAssertTrue(engine.visibleOverlay(now: inputTime + 0.071).cells.isEmpty)

        engine.observeAuthoritativeState(
            makeState(rowText: "ac", cursorColumn: 2, cursorVersion: 3),
            now: inputTime + 0.08
        )

        XCTAssertFalse(engine.hasEchoConfidence)
        XCTAssertEqual(engine.observeLocalInput(.directText("d"), now: inputTime + 0.081), .hiddenPendingEcho)
        XCTAssertEqual(engine.debugPendingTextForTests, "d")
        XCTAssertTrue(engine.visibleOverlay(now: inputTime + 0.132).cells.isEmpty)
    }

    func testMultipleBackspacesKeepErasedTailUntilAuthoritativeCatchUp() {
        var engine = makeEchoConfidentEngine()
        let inputTime = start + 0.1

        XCTAssertEqual(engine.observeLocalInput(.directText("b"), now: inputTime), .accepted)
        XCTAssertEqual(engine.observeLocalInput(.directText("c"), now: inputTime + 0.01), .accepted)
        XCTAssertEqual(engine.observeLocalInput(.directText("d"), now: inputTime + 0.02), .accepted)
        XCTAssertEqual(
            engine.visibleOverlay(now: inputTime + 0.08).cells.map { $0.cell.text },
            ["b", "c", "d"]
        )

        XCTAssertEqual(engine.observeLocalInput(.plainErase(), now: inputTime + 0.09), .accepted)
        XCTAssertEqual(engine.observeLocalInput(.plainErase(), now: inputTime + 0.091), .accepted)
        XCTAssertEqual(
            engine.visibleOverlay(now: inputTime + 0.092).cells.map { $0.cell.text },
            ["b"]
        )

        engine.observeAuthoritativeState(
            makeState(rowText: "abcd", cursorColumn: 4, cursorVersion: 3),
            now: inputTime + 0.1
        )

        XCTAssertTrue(engine.hasEchoConfidence)
        XCTAssertFalse(engine.isCoolingDown(now: inputTime + 0.101))

        engine.observeAuthoritativeState(
            makeState(rowText: "ab", cursorColumn: 2, cursorVersion: 4),
            now: inputTime + 0.11
        )

        XCTAssertEqual(engine.observeLocalInput(.directText("e"), now: inputTime + 0.111), .accepted)
        let overlay = engine.visibleOverlay(now: inputTime + 0.162)
        XCTAssertEqual(overlay.cells.map { $0.cell.text }, ["e"])
        XCTAssertEqual(overlay.cells.map { $0.column }, [2])
    }

    func testSingleWidthPredictionDoesNotSplitAuthoritativeWidthTwoCell() {
        var engine = makeEngine()
        let wideRow: [RemoteGridCell] = [.text("界", width: 2), .continuation, .blank]
        let provenRow: [RemoteGridCell] = [.text("界", width: 2), .continuation, .text("a")]
        engine.observeAuthoritativeState(makeState(rowCells: wideRow, cursorColumn: 2))

        XCTAssertEqual(engine.observeLocalInput(.directText("a"), now: start), .hiddenPendingEcho)
        engine.observeAuthoritativeState(
            makeState(rowCells: provenRow, cursorColumn: 3, cursorVersion: 2),
            now: start + 0.01
        )
        XCTAssertTrue(engine.hasEchoConfidence)

        engine.observeAuthoritativeState(makeState(rowCells: provenRow, cursorColumn: 0, cursorVersion: 3))
        let inputTime = start + 0.1
        let result = engine.observeLocalInput(.directText("x"), now: inputTime)
        XCTAssertTrue(result == .rejected || result == .forwardOnly)
        XCTAssertTrue(engine.visibleOverlay(now: inputTime + 0.051).cells.isEmpty)
    }

    func testPredictionDoesNotStartOnAuthoritativeContinuationCell() {
        var engine = makeEngine()
        let wideRow: [RemoteGridCell] = [.text("界", width: 2), .continuation, .blank]
        let provenRow: [RemoteGridCell] = [.text("界", width: 2), .continuation, .text("a")]
        engine.observeAuthoritativeState(makeState(rowCells: wideRow, cursorColumn: 2))

        XCTAssertEqual(engine.observeLocalInput(.directText("a"), now: start), .hiddenPendingEcho)
        engine.observeAuthoritativeState(
            makeState(rowCells: provenRow, cursorColumn: 3, cursorVersion: 2),
            now: start + 0.01
        )
        XCTAssertTrue(engine.hasEchoConfidence)

        engine.observeAuthoritativeState(makeState(rowCells: provenRow, cursorColumn: 1, cursorVersion: 3))
        let inputTime = start + 0.1
        let result = engine.observeLocalInput(.directText("x"), now: inputTime)
        XCTAssertTrue(result == .rejected || result == .forwardOnly)
        XCTAssertTrue(engine.visibleOverlay(now: inputTime + 0.051).cells.isEmpty)
    }

    func testWidthTwoPrintableOverlayIncludesContinuationCell() {
        var engine = makeEchoConfidentEngine()
        let inputTime = start + 0.1

        XCTAssertEqual(engine.observeLocalInput(.directText("界"), now: inputTime), .accepted)

        let overlay = engine.visibleOverlay(now: inputTime + 0.051)
        XCTAssertEqual(overlay.cells.count, 2)
        XCTAssertEqual(overlay.cells.first?.column, 1)
        XCTAssertEqual(overlay.cells.first?.cell.text, "界")
        XCTAssertEqual(overlay.cells.first?.cell.width, 2)
        XCTAssertEqual(overlay.cells.dropFirst().first?.column, 2)
        XCTAssertEqual(overlay.cells.dropFirst().first?.cell, .continuation)
        XCTAssertEqual(overlay.cursor?.column, 3)
    }

    func testPrintableWiderThanTwoCellsIsRejected() {
        var engine = makeEchoConfidentEngine()
        let inputTime = start + 0.1

        XCTAssertEqual(engine.observeLocalInput(.directText("👩‍💻"), now: inputTime), .rejected)
        XCTAssertFalse(engine.hasEchoConfidence)
        XCTAssertTrue(engine.visibleOverlay(now: inputTime + 0.051).cells.isEmpty)
    }

    func testPartialVisibleAcknowledgementDetectsRemainingPredictionMismatch() {
        var engine = makeEchoConfidentEngine()
        let inputTime = start + 0.1

        XCTAssertEqual(engine.observeLocalInput(.directText("b"), now: inputTime), .accepted)
        XCTAssertEqual(engine.observeLocalInput(.directText("c"), now: inputTime + 0.01), .accepted)

        engine.observeAuthoritativeState(
            makeState(rowText: "abz", cursorColumn: 3, cursorVersion: 3),
            now: inputTime + 0.08
        )

        XCTAssertFalse(engine.hasEchoConfidence)
        XCTAssertTrue(engine.visibleOverlay(now: inputTime + 0.08).cells.isEmpty)
        XCTAssertTrue(engine.isCoolingDown(now: inputTime + 0.08))
    }

    func testCoalescedVisibleAcknowledgementConsumesContiguousPendingRun() {
        var engine = makeEchoConfidentEngine()
        let inputTime = start + 0.1

        XCTAssertEqual(engine.observeLocalInput(.directText("b"), now: inputTime), .accepted)
        XCTAssertEqual(engine.observeLocalInput(.directText("c"), now: inputTime + 0.01), .accepted)

        engine.observeAuthoritativeState(
            makeState(
                rowText: "abc",
                cursorColumn: 3,
                cursorVersion: 3
            ),
            now: inputTime + 0.08
        )

        XCTAssertTrue(engine.hasEchoConfidence)
        XCTAssertFalse(engine.isCoolingDown(now: inputTime + 0.08))
        XCTAssertTrue(engine.visibleOverlay(now: inputTime + 0.08).cells.isEmpty)

        XCTAssertEqual(engine.observeLocalInput(.directText("d"), now: inputTime + 0.09), .accepted)
        let overlay = engine.visibleOverlay(now: inputTime + 0.141)
        XCTAssertEqual(overlay.cells.map { $0.cell.text }, ["d"])
        XCTAssertEqual(overlay.cells.first?.column, 3)
    }

    func testCursorMovementBeforeRemainingChainedPredictionClearsOverlayAndStartsCooldown() {
        var engine = makeEchoConfidentEngine()
        let inputTime = start + 0.1

        XCTAssertEqual(engine.observeLocalInput(.directText("b"), now: inputTime), .accepted)
        XCTAssertEqual(engine.observeLocalInput(.directText("c"), now: inputTime + 0.01), .accepted)

        engine.observeAuthoritativeState(
            makeState(
                rowText: "ab",
                cursorColumn: 2,
                cursorVersion: 3
            ),
            now: inputTime + 0.08
        )

        let remainingOverlay = engine.visibleOverlay(now: inputTime + 0.081)
        XCTAssertEqual(remainingOverlay.cells.map { $0.cell.text }, ["c"])
        XCTAssertEqual(remainingOverlay.cells.map { $0.column }, [2])

        let mismatchTime = inputTime + 0.09
        engine.observeAuthoritativeState(
            makeState(
                rowText: "ab",
                cursorColumn: 1,
                cursorVersion: 4
            ),
            now: mismatchTime
        )

        XCTAssertFalse(engine.hasEchoConfidence)
        XCTAssertTrue(engine.visibleOverlay(now: mismatchTime + 0.01).cells.isEmpty)
        XCTAssertTrue(engine.isCoolingDown(now: mismatchTime + 0.01))
    }

    func testVisibleAcknowledgementWithContradictoryCursorMovementClearsOverlayAndStartsCooldown() {
        var engine = makeEchoConfidentEngine()
        let inputTime = start + 0.1

        XCTAssertEqual(engine.observeLocalInput(.directText("b"), now: inputTime), .accepted)

        let mismatchTime = inputTime + 0.08
        engine.observeAuthoritativeState(
            makeState(rowText: "ab", cursorColumn: 5, cursorVersion: 3),
            now: mismatchTime
        )

        XCTAssertFalse(engine.hasEchoConfidence)
        XCTAssertTrue(engine.visibleOverlay(now: mismatchTime + 0.01).cells.isEmpty)
        XCTAssertTrue(engine.isCoolingDown(now: mismatchTime + 0.01))
    }

    func testVisibleAcknowledgementDoesNotConsumePredictionWithoutCursorProof() {
        var engine = makeEchoConfidentEngine()
        let inputTime = start + 0.1

        XCTAssertEqual(engine.observeLocalInput(.directText("b"), now: inputTime), .accepted)
        engine.observeAuthoritativeState(
            makeState(
                rowText: "ab",
                cursorColumn: 2,
                cursorVersion: 2
            ),
            now: inputTime + 0.08
        )

        let overlay = engine.visibleOverlay(now: inputTime + 0.08)
        XCTAssertEqual(overlay.cells.map { $0.cell.text }, ["b"])
        XCTAssertEqual(overlay.cells.first?.column, 1)
        XCTAssertTrue(engine.hasEchoConfidence)
        XCTAssertFalse(engine.isCoolingDown(now: inputTime + 0.08))
    }

    func testVisibleCursorProofWithoutMatchingTextContradictsPrediction() {
        var engine = makeEchoConfidentEngine()
        let inputTime = start + 0.1

        XCTAssertEqual(engine.observeLocalInput(.directText("b"), now: inputTime), .accepted)

        let mismatchTime = inputTime + 0.08
        engine.observeAuthoritativeState(
            makeState(
                rowText: "a",
                cursorColumn: 2,
                cursorVersion: 3
            ),
            now: mismatchTime
        )

        XCTAssertFalse(engine.hasEchoConfidence)
        XCTAssertTrue(engine.visibleOverlay(now: mismatchTime + 0.01).cells.isEmpty)
        XCTAssertTrue(engine.isCoolingDown(now: mismatchTime + 0.01))
    }

    func testVisibleSameGlyphAcknowledgementConsumesPredictionWithCursorProof() {
        var engine = makeEngine()
        engine.observeAuthoritativeState(makeState(rowText: "a c", cursorColumn: 1))
        XCTAssertEqual(engine.observeLocalInput(.directText("b"), now: start), .hiddenPendingEcho)
        engine.observeAuthoritativeState(
            makeState(rowText: "abc", cursorColumn: 2, cursorVersion: 2),
            now: start + 0.01
        )
        XCTAssertTrue(engine.hasEchoConfidence)

        let inputTime = start + 0.1

        XCTAssertEqual(engine.observeLocalInput(.directText("c"), now: inputTime), .accepted)

        engine.observeAuthoritativeState(
            makeState(
                rowText: "abc",
                cursorColumn: 3,
                cursorVersion: 3
            ),
            now: inputTime + 0.08
        )

        let overlay = engine.visibleOverlay(now: inputTime + 0.08)
        XCTAssertTrue(overlay.cells.isEmpty)
        XCTAssertTrue(engine.hasEchoConfidence)
        XCTAssertFalse(engine.isCoolingDown(now: inputTime + 0.08))

        XCTAssertEqual(engine.observeLocalInput(.directText("d"), now: inputTime + 0.09), .accepted)
        let nextOverlay = engine.visibleOverlay(now: inputTime + 0.141)
        XCTAssertEqual(nextOverlay.cells.map { $0.cell.text }, ["d"])
        XCTAssertEqual(nextOverlay.cells.first?.column, 3)
    }

    func testVisibleContradictionUnderLaterPendingCellClearsOverlayAndStartsCooldown() {
        var engine = makeEchoConfidentEngine()
        let inputTime = start + 0.1

        XCTAssertEqual(engine.observeLocalInput(.directText("b"), now: inputTime), .accepted)
        XCTAssertEqual(engine.observeLocalInput(.directText("c"), now: inputTime + 0.01), .accepted)

        let mismatchTime = inputTime + 0.08
        engine.observeAuthoritativeState(
            makeState(
                rowCells: [.text("a"), .blank, .text("z")],
                cursorColumn: 1,
                cursorVersion: 3
            ),
            now: mismatchTime
        )

        XCTAssertFalse(engine.hasEchoConfidence)
        XCTAssertTrue(engine.visibleOverlay(now: mismatchTime + 0.01).cells.isEmpty)
        XCTAssertTrue(engine.isCoolingDown(now: mismatchTime + 0.01))
    }

    func testVisiblePendingWithUnrelatedAuthoritativeCursorMovementClearsOverlayAndStartsCooldown() {
        var engine = makeEchoConfidentEngine()
        let inputTime = start + 0.1

        XCTAssertEqual(engine.observeLocalInput(.directText("b"), now: inputTime), .accepted)

        let mismatchTime = inputTime + 0.08
        engine.observeAuthoritativeState(
            makeState(rowText: "a", cursorColumn: 5, cursorVersion: 3),
            now: mismatchTime
        )

        XCTAssertFalse(engine.hasEchoConfidence)
        XCTAssertTrue(engine.visibleOverlay(now: mismatchTime + 0.01).cells.isEmpty)
        XCTAssertTrue(engine.isCoolingDown(now: mismatchTime + 0.01))
    }

    func testVisibleMismatchAcrossCursorVersionProgressClearsOverlayAndStartsCooldown() {
        var engine = makeEchoConfidentEngine()
        let inputTime = start + 0.1

        XCTAssertEqual(engine.observeLocalInput(.directText("b"), now: inputTime), .accepted)
        XCTAssertEqual(engine.observeLocalInput(.directText("c"), now: inputTime + 0.01), .accepted)

        let mismatchTime = inputTime + 0.08
        engine.observeAuthoritativeState(
            makeState(rowText: "abz", cursorColumn: 3, cursorVersion: 3),
            now: mismatchTime
        )

        XCTAssertFalse(engine.hasEchoConfidence)
        XCTAssertTrue(engine.visibleOverlay(now: mismatchTime + 0.01).cells.isEmpty)
        XCTAssertTrue(engine.isCoolingDown(now: mismatchTime + 0.01))
    }

    func testDebugDescriptionDoesNotIncludePredictedText() {
        var engine = makeEngine()
        engine.observeAuthoritativeState(makeState())

        XCTAssertEqual(engine.observeLocalInput(.directText("Ω"), now: start), .hiddenPendingEcho)
        XCTAssertEqual(engine.debugPendingTextForTests, "Ω")
        XCTAssertFalse(String(describing: engine).contains("Ω"))
    }

    private func makeEchoConfidentEngine() -> RemotePredictiveEchoEngine {
        var engine = makeEngine()
        engine.observeAuthoritativeState(makeState())
        XCTAssertEqual(engine.observeLocalInput(.directText("a"), now: start), .hiddenPendingEcho)
        engine.observeAuthoritativeState(
            makeState(rowText: "a", cursorColumn: 1, cursorVersion: 2),
            now: start + 0.01
        )
        XCTAssertTrue(engine.hasEchoConfidence)
        return engine
    }

    private func makeEngine(
        latencyThreshold: TimeInterval = 0.05,
        noAckTimeout: TimeInterval = 0.5,
        cooldownDuration: TimeInterval = 0.5
    ) -> RemotePredictiveEchoEngine {
        RemotePredictiveEchoEngine(
            latencyThreshold: latencyThreshold,
            noAckTimeout: noAckTimeout,
            cooldownDuration: cooldownDuration
        )
    }

    private func makeState(
        rowText: String = "",
        keyframeID: UInt64 = 11,
        cursorRow: Int = 0,
        cursorColumn: Int = 0,
        cursorVersion: UInt64 = 1,
        activeScreen: RemoteActiveScreen = .primary,
        cursorVisible: Bool = true
    ) -> RemotePaneGridState {
        var state = RemotePaneGridState()
        let result = state.apply(RemotePaneKeyframe(
            workspaceID: "workspace-1",
            paneID: 7,
            paneGeneration: 3,
            keyframeID: keyframeID,
            gridSize: RemoteGridSize(columns: 6, rows: 2),
            rows: [
                RemoteGridRow(index: 0, rowVersion: cursorVersion, cells: makeCells(rowText, columns: 6)),
                RemoteGridRow(index: 1, rowVersion: 1, cells: makeCells("", columns: 6))
            ],
            cursor: RemoteCursorState(
                row: cursorRow,
                column: cursorColumn,
                visible: cursorVisible,
                shape: .block,
                cursorVersion: cursorVersion
            ),
            activeScreen: activeScreen,
            datagramsEnabledAfterKeyframe: true
        ))
        XCTAssertEqual(result, .applied)
        return state
    }

    private func makeState(
        rowCells: [RemoteGridCell],
        keyframeID: UInt64 = 11,
        cursorRow: Int = 0,
        cursorColumn: Int = 0,
        cursorVersion: UInt64 = 1,
        activeScreen: RemoteActiveScreen = .primary,
        cursorVisible: Bool = true
    ) -> RemotePaneGridState {
        var state = RemotePaneGridState()
        let result = state.apply(RemotePaneKeyframe(
            workspaceID: "workspace-1",
            paneID: 7,
            paneGeneration: 3,
            keyframeID: keyframeID,
            gridSize: RemoteGridSize(columns: 6, rows: 2),
            rows: [
                RemoteGridRow(index: 0, rowVersion: cursorVersion, cells: padCells(rowCells, columns: 6)),
                RemoteGridRow(index: 1, rowVersion: 1, cells: makeCells("", columns: 6))
            ],
            cursor: RemoteCursorState(
                row: cursorRow,
                column: cursorColumn,
                visible: cursorVisible,
                shape: .block,
                cursorVersion: cursorVersion
            ),
            activeScreen: activeScreen,
            datagramsEnabledAfterKeyframe: true
        ))
        XCTAssertEqual(result, .applied)
        return state
    }

    private func makeCells(_ text: String, columns: Int) -> [RemoteGridCell] {
        padCells(text.map { RemoteGridCell.text(String($0)) }, columns: columns)
    }

    private func padCells(_ input: [RemoteGridCell], columns: Int) -> [RemoteGridCell] {
        var cells = input
        while cells.count < columns {
            cells.append(.blank)
        }
        return Array(cells.prefix(columns))
    }
}

private extension RemotePaneInput {
    static func directText(_ text: String) -> RemotePaneInput {
        RemotePaneInput(data: Data(text.utf8), source: .directKey)
    }

    static func directBytes(_ bytes: [UInt8]) -> RemotePaneInput {
        RemotePaneInput(data: Data(bytes), source: .directKey)
    }

    static func paste(_ text: String) -> RemotePaneInput {
        RemotePaneInput(data: Data(text.utf8), source: .paste)
    }

    static func imeCommit(_ text: String) -> RemotePaneInput {
        RemotePaneInput(data: Data(text.utf8), source: .imeCommit)
    }

    static func escapeSequence() -> RemotePaneInput {
        RemotePaneInput(data: Data([0x1B, 0x5B, 0x41]), source: .escapeSequence)
    }

    static func plainErase(_ byte: UInt8 = 0x7F) -> RemotePaneInput {
        RemotePaneInput(data: Data([byte]), source: .plainEraseByte)
    }
}
