import XCTest
@testable import Fantastty

final class AttachedWorkspaceRuntimeV2Tests: XCTestCase {
    func testLayoutBeforeWindowAddBuffersAndFlushesBufferedOutput() {
        var runtime = AttachedWorkspaceRuntimeV2()
        let layout = "bb62,213x55,0,0,7"
        let payload = Data("hello".utf8)

        let layoutActions = runtime.handle(.layoutChanged(windowID: 1, layout: layout))
        XCTAssertTrue(layoutActions.isEmpty)

        let outputActions = runtime.handle(.paneOutput(paneID: 7, data: payload))
        XCTAssertTrue(outputActions.isEmpty)

        let actions = runtime.handle(
            .windowAdded(
                Fantastty.TmuxWindow(windowID: 1, name: "main", paneIDs: [], windowIndex: 0, isActive: true)
            )
        )

        XCTAssertEqual(
            actions,
            [
                .upsertWindow(
                    .init(windowID: 1, title: "main", windowIndex: 0, isActive: true)
                ),
                .applyLayout(windowID: 1, layout: layout, paneIDs: [7]),
                .deliverPaneOutput(windowID: 1, paneID: 7, data: payload)
            ]
        )
    }

    func testWindowCloseDropsBufferedOutputWhenAllWindowsGone() {
        var runtime = AttachedWorkspaceRuntimeV2()
        let stale = Data("stale".utf8)
        let layout = "bb62,213x55,0,0,7"

        _ = runtime.handle(
            .windowAdded(
                Fantastty.TmuxWindow(windowID: 1, name: "one", paneIDs: [], windowIndex: 0, isActive: true)
            )
        )
        _ = runtime.handle(.paneOutput(paneID: 7, data: stale))
        _ = runtime.handle(.windowClosed(windowID: 1))

        _ = runtime.handle(
            .windowAdded(
                Fantastty.TmuxWindow(windowID: 2, name: "two", paneIDs: [], windowIndex: 1, isActive: true)
            )
        )
        let actions = runtime.handle(.layoutChanged(windowID: 2, layout: layout))

        XCTAssertEqual(
            actions,
            [
                .applyLayout(windowID: 2, layout: layout, paneIDs: [7])
            ]
        )
        XCTAssertFalse(actions.contains(where: {
            if case .deliverPaneOutput = $0 { return true }
            return false
        }))
    }

    func testOutputBeforePaneIsBufferedUntilPaneAppearsInLaterLayout() {
        var runtime = AttachedWorkspaceRuntimeV2()
        let early = Data("early".utf8)
        let firstLayout = "bb62,213x55,0,0,7"
        let secondLayout = "bb62,213x55,0,0{106x55,0,0,7,106x55,107,0,9}"

        _ = runtime.handle(
            .windowAdded(
                Fantastty.TmuxWindow(windowID: 1, name: "main", paneIDs: [], windowIndex: 0, isActive: true)
            )
        )
        _ = runtime.handle(.layoutChanged(windowID: 1, layout: firstLayout))

        let buffered = runtime.handle(.paneOutput(paneID: 9, data: early))
        XCTAssertTrue(buffered.isEmpty)

        let flushed = runtime.handle(.layoutChanged(windowID: 1, layout: secondLayout))
        XCTAssertEqual(
            flushed,
            [
                .applyLayout(windowID: 1, layout: secondLayout, paneIDs: [7, 9]),
                .deliverPaneOutput(windowID: 1, paneID: 9, data: early)
            ]
        )
    }
}
